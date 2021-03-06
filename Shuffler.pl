#!/usr/bin/perl -w
use strict;
use Getopt::Std;

my $version = 0.1;

my $help = "
Shuffler.pl : Prediction of plant miRNA target sites, including control of false discovery rates, based on shuffled controls

Version: $version

Usage: Shuffler.pl [options] -s <sequence> -d <transcriptome.fasta> > output_table.txt

Options:
 -q <string> : Query name (deafults to 'query').
 -c <float> : Max score to test for (default = 8).
 -t <int> : # of threads for Smith-Waterman search (default = 1).
 -n <int> : Number of shuffle permutations used to derived median value (default = 10).
 -f <float> : False discovery rate .. alignments estimated to have FDR at or below this (default = 0.25).
 -r       : Also search the reverse strand for targets.
 -a       : Show all alignments regardless of FDR cutoff
 -h       : Print this message and quit.

Dependencies (must be in PATH):
 targetfinder.pl  : From github.com/MikeAxtell/TargetFinder  .. edit code to match up to your version of ssearch from FASTA
     ## credit to Noah Fahlgren / Carrington Lab for targetfinder.pl .. forked from their github repo Sep 2016.
 ssearch36 : Smith-Waterman aligner from FASTA package .. http://fasta.bioch.virginia.edu/fasta_www2/fasta_down.shtml
 uShuffle : Compiled C binary from http://digital.cs.usu.edu/~mjiang/ushuffle/ (rename it to uShuffle)

Documentation: perldoc Shuffler.pl or see README_Shuffler

";

my %opt = ();
# set defaults .. those not set here are set by targetfinder.pl
$opt{'c'} = 8;
$opt{'n'} = 10;
$opt{'f'} = 0.25;
getopts('d:s:q:c:t:n:f:rah', \%opt);

# give help if requested
if($opt{'h'}) {
    die "$help\n";
}

# check for uShuffle and targetfinder.pl
open(US, "which uShuffle |");
my $us_check = <US>;
close US;
if(!$us_check) {
    die "Required program uShuffle not found in \$PATH\n\n$help\n\n";
}

open(TF, "which targetfinder.pl |");
my $tf_check = <TF>;
close TF;
if(!$tf_check) {
    die "Required program targetfinder.pl not found in \$PATH\n\n$help\n\n";
}

# check for required options -s and -d
unless(($opt{'s'}) and ($opt{'d'})) {
    die "Both options -s and -d are required.\n\n$help\n\n";
}

# build a generic command chunk
my $c_chunk = "-c $opt{'c'} -d $opt{'d'} -p table";
if($opt{'t'}) {
    $c_chunk .= " -t $opt{'t'}";
}
if($opt{'r'}) {
    $c_chunk .= " -r";
}
if($opt{'q'}) {
    $c_chunk .= " -q $opt{'q'}";
}

print STDERR "Shuffler.pl version $version\n";

print STDERR "Searching against input query $opt{'s'}\n";
# Call the real query, store all results
open(TFR, "targetfinder.pl -s $opt{'s'} $c_chunk |");
my @real_hits = <TFR>;
close TFR;

# Store counts of true hits
my %true_simple = ();
for(my $i = 0; $i <= $opt{'c'}; $i += 0.5) {
    $true_simple{$i} = 0;
}
foreach my $real_hit (@real_hits) {
    my @rh_fields = split ("\t", $real_hit);
    ++$true_simple{$rh_fields[5]};
}

# Tally up the true hits - cumulative
my %true_cumulative = ();
my $tc = 0;
for(my $i = 0; $i <= $opt{'c'}; $i += 0.5) {
    $tc += $true_simple{$i};
    $true_cumulative{$i} = $tc;
}

# prepare for shuffling
my %notOK = ($opt{'s'} => 1);
my %shuf_arrays = ();

# shuffle loop
for(my $i = 1; $i <= $opt{'n'}; ++$i) {
    my $shufseq = get_shuf(\$opt{'s'}, \%notOK);
    
    # test
    #print "shufseq with no newline after it is $shufseq";
    #exit;
    
    $notOK{$shufseq} = 1;
    my %shuf_single = ();
    for(my $j = 0; $j <= $opt{'c'}; $j += 0.5) {
	$shuf_single{$j} = 0;
    }
    print STDERR "Searching against shuffled permutation number $i $shufseq\n";
    open(TF, "targetfinder.pl -s $shufseq $c_chunk |");
    while (<TF>) {
	chomp;
	my @tf_f = split ("\t", $_);
	++$shuf_single{$tf_f[5]};
    }
    close TF;
    for(my $j = 0; $j <= $opt{'c'}; $j += 0.5) {
	push(@{$shuf_arrays{$j}}, $shuf_single{$j});
    }
}

# calculations for shuffles .. medians, cumulative median, and inverse-cumulative median
my %shuf_median_simple = ();
for(my $k = 0; $k <= $opt{'c'}; $k += 0.5) {
    my $med = median(@{$shuf_arrays{$k}});
    $shuf_median_simple{$k} = $med;
}
my %shuf_median_cumulative = ();
my $smc = 0;
for(my $k = 0; $k <= $opt{'c'}; $k += 0.5) {
    $smc += $shuf_median_simple{$k};
    $shuf_median_cumulative{$k} = $smc;
}
my %shuf_median_inverse_cumulative = ();
my $sic;
for(my $k = 0; $k <= $opt{'c'}; $k += 0.5) {
    $sic = $shuf_median_cumulative{$opt{'c'}} - $shuf_median_cumulative{$k};
    $shuf_median_inverse_cumulative{$k} = $sic;
}

# Calculate the confusion matrix
my %TP = ();
my %FP = ();
my %TN = ();
my %FN = ();

my %acc = ();
my %f1 = ();
my %fdr = ();


for(my $i = 0; $i <= $opt{'c'}; $i += 0.5) {
    my $P = $true_cumulative{$i}; ## Positives are all hits from real query at a given score
    my $N = $true_cumulative{$opt{'c'}} - $P; ## Negatives are the remainder of hits from the real query
    
    my $tp_a = $P - $shuf_median_cumulative{$i}; ## TP are excess number of hits with real query vs. control
    $TP{$i} = ($tp_a > 0) ? $tp_a : 0;  ## Boundary condition, TP can't be less than 0.
    $FP{$i} = $P - $TP{$i};  ## Logically, FPs are P - TP.
    
    my $fn_a = $N - $shuf_median_inverse_cumulative{$i}; ## FN are N's in excess of what is found with real query
    $FN{$i} = ($fn_a > 0) ? $fn_a : 0; ## Boundary condition, FN can't be less than 0.
    $TN{$i} = $N - $FN{$i}; ## Logically, TNs are N - FN.
    
    $acc{$i} = ACC($TP{$i}, $TN{$i}, $FP{$i}, $FN{$i});
    # $f1{$i} = F1($TP{$i}, $FP{$i}, $FN{$i});
    $fdr{$i} = FDR($FP{$i}, $TP{$i});
}
 
# Report stats to user
print STDERR "\n\nResults \(HitsC and ShufC .. the C means Cumulative\)\n";
print STDERR "Score\tHitsC\tShufC";
print STDERR "\tTP\tFP\tFN\tTN";
print STDERR "\tACC\tFDR\n";
for(my $k = 0; $k <= $opt{'c'}; $k += 0.5) {
    print STDERR "$k\t";
    print STDERR "$true_cumulative{$k}\t";
    print STDERR "$shuf_median_cumulative{$k}\t";
    print STDERR "$TP{$k}\t$FP{$k}\t$FN{$k}\t$TN{$k}\t";
    print STDERR "$acc{$k}\t$fdr{$k}\n";
}

# Determine cutoff
my $cutoff = $opt{'c'};
for(my $k = 0; $k <= $opt{'c'}; $k += 0.5) {
    if($fdr{$k} =~ /\d/) {
	if($fdr{$k} > $opt{'f'}) {
	    $cutoff = $k - 0.5;
	    last;
	}
    }
}

# Get the keepers
my @keepers = ();
foreach my $real_hit (@real_hits) {
    my @r_h_f = split ("\t", $real_hit);
    if($r_h_f[5] <= $cutoff) {
	push(@keepers, $real_hit);
    }
}

# Report
print STDERR "\nCutoff for FDR \<\=$opt{'f'}: $cutoff\n";
unless(@keepers) {
    print STDERR "NO predictions scored at or below the cutoff\!\n";
}
if(($opt{'a'}) and (@real_hits)) {
    print STDERR "ALL predictions being printed, regardless of FDR, because option -a was activated\n";
    foreach my $xxx (@real_hits) {
	print $xxx;
    }
} elsif (@keepers) {
    foreach my $yyy (@keepers) {
	print $yyy;
    }
}



sub TPR {
    # AKA Sensitivity: TP / (TP + FN)
    my($tp, $fn) = @_;
    my $denom = $tp + $fn;
    if($denom > 0) {
	my $TPR = sprintf("%.3f", $tp / $denom);
	return $TPR;
    } else {
	return 'NA';
    }
}

sub TNR {
    # AKA Specificity: TN / (TN + FP)
    my($tn, $fp) = @_;
    my $denom = $tn + $fp;
    if($denom > 0) {
	my $TNR = sprintf("%.3f", $tn / $denom);
	return $TNR;
    } else {
	return 'NA';
    }
}

sub PPV {
    # AKA Positive Predictive Value: TP / (TP + FP)
    my($tp, $fp) = @_;
    my $denom = $tp + $fp;
    if($denom > 0) {
	my $PPV = sprintf("%.3f", $tp / $denom);
	return $PPV;
    } else {
	return 'NA';
    }
}

sub NPV {
    # Negative Predictive Value: TN / (TN + FN)
    my($tn, $fn) = @_;
    my $denom = $tn + $fn;
    if($denom > 0) {
	my $NPV = sprintf("%.3f", $tn / $denom);
	return $NPV;
    } else {
	return 'NA';
    }
}

sub FPR {
    # False Positive Rate: FP / (FP + TN)
    my($fp, $tn) = @_;
    my $denom = $fp + $tn;
    if($denom > 0) {
	my $FPR = sprintf("%.3f", $fp / $denom);
	return $FPR;
    } else {
	return 'NA';
    }
}

sub FNR {
    # False Negative Rate: FN / (FN + TP)
    my($fn, $tp) = @_;
    my $denom = $fn + $tp;
    if($denom > 0) {
	my $FNR = sprintf("%.3f", $fn / $denom);
	return $FNR;
    } else {
	return 'NA';
    }
}

sub FDR {
    # False Discovery Rate: FP / (FP + TP)
    my ($fp, $tp) = @_;
    my $denom = $fp + $tp;
    if($denom > 0) {
	my $FDR = sprintf("%.3f", $fp / $denom);
	return $FDR;
    } else {
	return 'NA';
    }
}

sub ACC {
    # Accuracy: (TP + TN) / (TP + TN + FP + FN)
    my($tp, $tn, $fp, $fn) = @_;
    my $denom = $tp + $tn + $fp + $fn;
    if($denom > 0) {
	my $numer = $tp + $tn;
	my $ACC = sprintf("%.3f", $numer / $denom);
	return $ACC;
    } else {
	return 'NA';
    }
}

sub F1 {
    # (2 * TP) / ((2 * TP) + FP + FN)
    my($tp, $fp, $fn) = @_;
    my $denom = (2 * $tp) + $fp + $fn;
    my $numer = 2 * $tp;
    if($denom > 0) {
	my $F1 = sprintf("%.3f", $numer / $denom);
	return $F1;
    } else {
	return 'NA';
    }
}
    
sub median {
    my(@data) = @_;
    my @sorted = sort {$a <=> $b} @data;
    my $length = scalar @sorted;
    my $median;
    unless($length > 0) {
	print STDERR "\nFatal cant calculate a median from a non-exisitent dataset\n";
	$median = 'NA';
	return $median;
    }
    my $i = int($length / 2);
    if($length % 2) {
	# odd
	$median = int($sorted[$i]);
    } else {
	# even
	$median = int(($sorted[$i - 1] + $sorted[$i]) / 2);
    }
    return $median;
}
	


sub get_shuf {
    my($input, $hash) = @_;
    my $attempts = 0;
    my $ok = 0;
    my $output;
    until($ok) {
	if($attempts >= 10000) {
	    die "\nFAILURE: Sorry, couldn't find enough valid shuffles of $$input ... is the sequence low complexity?\n";
	}
	my $seed = int(rand(10000));
	open(SHUF, "uShuffle -s $$input -n 1 -k 2 -seed $seed |");
	$output = <SHUF>;
	chomp $output;
	close SHUF;
	unless(exists($$hash{$output})) {
	    $ok = 1;
	}
	++$attempts;
    }
    return $output;
}

__END__

=head1 SYNOPSIS

Shuffler.pl - False Discovery Rate esitmation and control for plant microRNA target prediction based on Carrington Lab's targetfinder.pl

=head1 AUTHOR

Michael J. Axtell, Penn State University, mja18@psu.edu

=head1 LICENSE

Shuffler.pl (c) 2016 Michael J. Axtell

This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 INSTALL

From https://github.com/MikeAxtell/TargetFinder, copy the 'targetfinder.pl' and 'Shuffler.pl' scripts to your PATH (for instance, /usr/local/bin/).

Retrieve and install ssearch36 from the FASTA package (http://fasta.bioch.virginia.edu/fasta_www2/fasta_down.shtml). Copy the compiled 'ssearch36' binary to your PATH. If you want to use some other version of ssearch, open up targetfinder.pl and edit the code accordingly so that correct binary name is specified.

Retrieve and install the uShuffle program from http://digital.cs.usu.edu/~mjiang/ushuffle/. Compile the C version on your system, and rename it from the default name of 'main.exe' to 'uShuffle'. Copy the 'uShuffle' binary to your PATH.

=head1 USAGE

Usage: Shuffler.pl [options] -s <sequence> -d <transcriptome.fasta> > output_table.txt

Options:

 -q <string> : Query name (deafults to 'query').

 -c <float> : Max score to test for (default = 8).

 -t <int> : # of threads for Smith-Waterman search (default = 1).

 -n <int> : Number of shuffle permutations used to derived median value (default = 10).

 -f <float> : False discovery rate .. alignments estimated to have FDR at or below this (default = 0.25).

 -r       : Also search the reverse strand for targets.

 -a       : Show all alignments regardless of FDR cutoff

 -h       : Print help message and quit.

=head1 OUTPUT

Predicted targets that meet the specified FDR cutoff are printed to STDOUT in the targetfinder.pl 'table' tab-delimited format.

Information about the run is sent to STDERR. Abbreviations:

HitsC: Cumulative number of hits with the true query

ShufC: Cumulative median number of hits from the shuffled queries.

TP: True Positives

FP: False Positives

FN: False Negatives

TN: True Negatives

ACC: Accuracy ... (TP + TN) / (TP + TN + FP + FN)

FDR: False Discovery Rate .. FP / (FP + TP)

=head1 METHODS

The basic idea is to compare the number of hits obtained with a real query to the number of hits expected from randomized control queries, and use that ratio to compute a false discover rate.

The shuffled queries are controlled (by uShuffle) to maintain identical dinucleotide content as the real query, so as to avoid any biases resulting from dinucleotide composition. 

'Positives' (P) are defined as the HitsC value at a given score cutoff, and 'Negatives' (N) are defined as the maximum HitsC value minus 'Positives'

From there, TP and FP are separated. TP are defined as Positives - ShufC, with a lower limit of zero. FP is then computed as P - TP.

FN is calculated as N - iShufC, where iShufC is the inverse of the ShufC value. TN is then calculated as N - FN.

=head1 NOTES AND CAVEATS

This method takes advantage of the long-known fact that many plant microRNA targets have frequencies of complementary sites in the transcriptome at rates far higher than is expected from random chance (for instance, see Rhoades et al. 2002 Cell PMID: 12202040 Figure 1).

However, lack of confident prediction by this method should not be taken to be evidence against the reality of any given target site. Instead, lack of evidence simply means that, using alignments alone, sites of that quality would be expected by random chance, and so further experimental evidence would be needed to support the idea of it being a target site.
