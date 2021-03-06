#!/usr/bin/perl -w

use warnings;
use strict;
use POSIX;
use Getopt::Long;
use File::Path;
use File::Basename;
use Pod::Usage;

=head1 NAME

generate_gatk_haplotypecaller_pipeline_makefile

=head1 SYNOPSIS

 generate_gatk_haplotypecaller_calling_pipeline_makefile [options]

  -s     sample file list giving the location of each sample
         column 1: sample name
         column 2: path of bam file
  -r     reference genome file
  -l     sequence length file
  -w     interval width
  -o     output directory
  -m     make file name

=head1 DESCRIPTION

This script generates the make file to discovery and genotype a set of individuals.

=cut

my $help;

my $outputDir = "";
my $slurmScriptsSubDir = "";
my $makeFile = "Makefile";
my $partition = "1000g";
my $sampleFile = "";
my $intervals = "";
my $intervalWidth = "";
my $refGenomeFASTAFile = "";
my $jvmMemory = "2g";

#initialize options
Getopt::Long::Configure ('bundling');

if(!GetOptions ('h'=>\$help,
                'o:s'=>\$outputDir,
                'd:s'=>\$slurmScriptsSubDir,
                'm:s'=>\$makeFile,
                'p:s'=>\$partition,
                's:s'=>\$sampleFile,
                'i:s'=>\$intervalWidth,
                'r:s'=>\$refGenomeFASTAFile,
                'j:s'=>\$jvmMemory
                )
  || !defined($outputDir)
  || !defined($makeFile)
  || !defined($sampleFile)
  || !defined($refGenomeFASTAFile))
{
    if ($help)
    {
        pod2usage(-verbose => 2);
    }
    else
    {
        pod2usage(1);
    }
}

#programs
#you can set the  maximum memory here to be whatever you want
my $gatk = "/net/fantasia/home/atks/dev/vt/comparisons/programs/jdk1.7.0_25/bin/java -jar -Xmx$jvmMemory " .
           "/net/fantasia/home/atks/dev/vt/comparisons/programs/GenomeAnalysisTK-3.5/GenomeAnalysisTK.jar";
my $java = "/net/fantasia/home/atks/dev/vt/comparisons/programs/jdk1.7.0_25/bin/java -jar -Xmx$jvmMemory";
my $gatkJar = "/net/fantasia/home/atks/dev/vt/comparisons/programs/GenomeAnalysisTK-3.5/GenomeAnalysisTK.jar";
my $vt = "/net/fantasia/home/atks/dev/vt/comparisons/programs/vt/vt";

printf("generate_gatk_haplotypecaller_pipeline_makefile.pl\n");
printf("\n");
printf("options: output dir              %s\n", $outputDir);
printf("         make file               %s\n", $makeFile);
printf("         partition               %s\n", $partition);
printf("         slurm scripts sub dir   %s\n", $slurmScriptsSubDir);
printf("         sample file             %s\n", $sampleFile);
printf("         interval width          %s\n", $intervalWidth);
printf("         reference               %s\n", $refGenomeFASTAFile);
printf("         JVM Memory              %s\n", $jvmMemory);
printf("\n");

my $vcfOutDir = "$outputDir/vcf";
mkpath($vcfOutDir);
my $finalVCFOutDir = "$outputDir/final";
mkpath($finalVCFOutDir);
my $logDir = "$outputDir/log";
mkpath($logDir);
my $auxDir = "$outputDir/aux";
mkpath($auxDir);
my $statsDir = "$outputDir/stats";
mkpath($statsDir);
my $slurmScriptsDir = "$outputDir/slurm_scripts/$slurmScriptsSubDir";
mkpath($slurmScriptsDir);
my $slurmScriptNo = 0;

my $logFile = "$outputDir/run.log";

########################################
#Read file locations and name of samples
########################################
my %SAMPLE = ();
my @sample = ();
open(SA,"$sampleFile") || die "Cannot open $sampleFile\n";
my $bamFiles = "";
while (<SA>)
{
    s/\r?\n?$//;
    if(!/^#/)
    {
        my ($sampleID, $bamPath) = split(/\s+/, $_);
        $SAMPLE{$sampleID} = $bamPath;
        push(@sample, $sampleID);
        $bamFiles .= "$bamPath\n";
    }
}
close(SA);

my $bamListFile = "$auxDir/bam.list";
open(OUT,">$bamListFile") || die "Cannot open $bamListFile\n";
print OUT $bamFiles;
close(OUT);

print "read in " . scalar(keys(%SAMPLE)) . " samples\n";

###################
#Generate intervals
###################
my %intervalsByChrom = ();
my @intervals = ();
my @CHROM = ();

my $writeIntervals = 1;

if (-e "$outputDir/intervals/$intervalWidth.OK")
{
    print "$outputDir/intervals/$intervalWidth.OK exists, intervals wil not be generated.\n";
    $writeIntervals = 0;
}

mkpath("$outputDir/intervals/");
open(SQ,"$refGenomeFASTAFile.fai") || die "Cannot open $refGenomeFASTAFile.fai\n";
while (<SQ>)
{
    s/\r?\n?$//;
    if(!/^#/)
    {
        my ($chrom, $len) = split('\t', $_);

        last if ($chrom=~/^GL/);
        
        print "processing $chrom\t$len ";

        push(@CHROM, $chrom);

        $intervalsByChrom{$chrom} = ();
        my $count = 0;
        for my $i (0 .. floor($len/$intervalWidth))
        {
            my $interval = "";
            my $file = "";
            if ($i<floor($len/$intervalWidth))
            {
                $interval = $chrom . "_" . ($intervalWidth*$i+1) . "_" . ($intervalWidth*($i+1));
                $file = "$outputDir/intervals/$interval.interval_list";
                if ($writeIntervals)
                {
                    open(INTERVAL, ">$file") || die "Cannot open $file\n";
                    print INTERVAL "$chrom:" . ($intervalWidth*$i+1) . "-" . ($intervalWidth*($i+1)) . "\n";
                    close(INTERVAL);
                }
            }
            elsif ($i*$intervalWidth!=$len)
            {
                $interval = $chrom . "_" . ($intervalWidth*$i+1) . "_" . $len;
                $file = "$outputDir/intervals/$interval.interval_list";
                if ($writeIntervals)
                {
                    open(INTERVAL, ">$file") || die "Cannot open $file\n";
                    print INTERVAL "$chrom:" . ($intervalWidth*$i+1) . "-" . $len . "\n";
                    close(INTERVAL);
                }
            }
            else
            {
                last;
            }

            push(@{$intervalsByChrom{$chrom}}, "$interval");
            push(@intervals, $interval);

            $count++;
        }

        print "added $count intervals\n";
    }
}
close(SQ);

if ($writeIntervals)
{
    print `touch $outputDir/intervals/$intervalWidth.OK`;
}

my @tgts = ();
my @deps = ();
my @cmds = ();
my $tgt;
my $dep;
my @cmd;
my $inputVCFFile;
my $outputVCFFile;

##########
#Discovery
##########

#****************************
#log start time for discovery
#****************************
$tgt = "$logDir/start.discovery.OK";
$dep = "";
@cmd = ("date | awk '{print \"gatk haplotypecaller pipeline\\n\\nstart: \"\$\$0}' > $logFile");
makeJob("local", $tgt, $dep, @cmd);

my %GVCFFilesByInterval = ();
my $GVCFFiles = "";
my $GVCFFilesOK = "";

for my $interval (@intervals)
{
    $GVCFFilesByInterval{$interval} = " ";

    for my $sampleID (@sample)
    {
        mkpath("$vcfOutDir/$sampleID");
        $outputVCFFile = "$vcfOutDir/$sampleID/$interval.vcf.gz";
        $tgt = "$outputVCFFile.OK";
        $dep = "";
        @cmd = ("$java -Djava.io.tmpdir=$vcfOutDir/$sampleID $gatkJar -T HaplotypeCaller -R $refGenomeFASTAFile -I $SAMPLE{$sampleID} " .
                "--emitRefConfidence GVCF --variant_index_type LINEAR --variant_index_parameter 128000 " .
                "-L $outputDir/intervals/$interval.interval_list " .
                "-o $outputVCFFile");
        makeJob($partition, $tgt, $dep, @cmd);

        $GVCFFilesByInterval{$interval} .= "$outputVCFFile\n";
        $GVCFFilesOK .= " $outputVCFFile.OK";
    }
}

#**************************
#log end time for discovery
#**************************
$tgt = "$logDir/end.discovery.OK";
$dep = "$GVCFFilesOK";
@cmd = ("date | awk '{print \"end discovery: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

############
#Combine VCF
############

#**********************************
#log start time for combining gvcfs
#**********************************
$tgt = "$logDir/start.combining_gvcfs.OK";
$dep = "$logDir/end.discovery.OK";
@cmd = ("date | awk '{print \"start combining gvcfs: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

my $mergedVCFFilesOK = "";

for my $interval (@intervals)
{
    my $gvcfListFile = "$auxDir/$interval.gvcf.list";
    open(OUT,">$gvcfListFile") || die "Cannot open $gvcfListFile\n";
    print OUT $GVCFFilesByInterval{$interval};
    close(OUT);

    $outputVCFFile = "$vcfOutDir/$interval.vcf";
    $tgt = "$outputVCFFile.OK";
    $dep = "$logDir/start.combining_gvcfs.OK";;
    @cmd = ("$java -Djava.io.tmpdir=$vcfOutDir $gatkJar -T CombineGVCFs -R $refGenomeFASTAFile -V $gvcfListFile -o $outputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);

    $mergedVCFFilesOK .= " $outputVCFFile.OK";
}

#********************************
#log end time for combining gvcfs
#********************************
$tgt = "$logDir/end.combining_gvcfs.OK";
$dep = "$mergedVCFFilesOK";
@cmd = ("date | awk '{print \"end combining gvcfs: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

#########
#Genotype
#########

#*****************************
#log start time for genotyping
#*****************************
$tgt = "$logDir/start.genotyping.OK";
$dep = "$logDir/end.combining_gvcfs.OK";
@cmd = ("date | awk '{print \"start genotyping: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

my $genotypeVCFFilesOK = "";

for my $interval (@intervals)
{
    $inputVCFFile = "$vcfOutDir/$interval.vcf";
    $outputVCFFile = "$vcfOutDir/$interval.genotypes.vcf";
    $tgt = "$outputVCFFile.OK";
    $dep = "$inputVCFFile.OK";
    @cmd = ("$gatk -T GenotypeGVCFs -R $refGenomeFASTAFile --variant $inputVCFFile -o $outputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);

    $genotypeVCFFilesOK .= " $outputVCFFile.OK";
}

#***************************
#log end time for genotyping
#***************************
$tgt = "$logDir/end.genotyping.OK";
$dep = "$genotypeVCFFilesOK";
@cmd = ("date | awk '{print \"end genotyping: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

###########################################
#Concatenate, normalize and drop duplicates
###########################################

#*********************************
#log start time for concating VCFs
#*********************************
$tgt = "$logDir/start.concatenation.OK";
$dep = "$logDir/end.genotyping.OK";
@cmd = ("date | awk '{print \"start concat and normalize: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

my $chromGenotypeVCFFilesOK = "";

for my $chrom (@CHROM)
{
    my $vcfListFile = "$auxDir/$chrom.vcf.list";
    open(OUT,">$vcfListFile") || die "Cannot open $vcfListFile\n";
    for my $interval (@{$intervalsByChrom{$chrom}})
    {
        print OUT "$vcfOutDir/$interval.genotypes.vcf.gz\n";
    }
    close(OUT);

    $outputVCFFile = "$finalVCFOutDir/$chrom.genotypes.vcf.gz";
    $tgt = "$outputVCFFile.OK";
    $dep = "$logDir/start.concatenation.OK";
    @cmd = ("$vt cat -L $vcfListFile -o + -w 1000 | $vt uniq + -o $outputVCFFile 2> $statsDir/$chrom.uniq.log");
    makeJob($partition, $tgt, $dep, @cmd);

    $tgt = "$outputVCFFile.tbi.OK";
    $dep = "$outputVCFFile.OK";
    @cmd = ("$vt index $outputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);

    $inputVCFFile = "$finalVCFOutDir/$chrom.genotypes.vcf.gz";
    $outputVCFFile = "$finalVCFOutDir/$chrom.sites.vcf.gz";
    $tgt = "$outputVCFFile.OK";
    $dep = "$inputVCFFile.OK";
    @cmd = ("$vt view -s $inputVCFFile -o $outputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);

    $inputVCFFile = "$finalVCFOutDir/$chrom.sites.vcf.gz";
    $outputVCFFile = "$finalVCFOutDir/$chrom.sites.vcf.gz.tbi";
    $tgt = "$outputVCFFile.OK";
    $dep = "$inputVCFFile.OK";
    @cmd = ("$vt index $inputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);
}

my $inputVCFFiles = join(" ", map {"$finalVCFOutDir/$_.genotypes.vcf.gz"} @CHROM);
my $inputVCFFilesOK = join(" ", map {"$finalVCFOutDir/$_.genotypes.vcf.gz.OK"} @CHROM);
$outputVCFFile = "$finalVCFOutDir/all.genotypes.vcf.gz";
$tgt = "$outputVCFFile.OK";
$dep = "$inputVCFFilesOK";
@cmd = ("$vt cat $inputVCFFiles -o $outputVCFFile");
makeJob($partition, $tgt, $dep, @cmd);

$inputVCFFile = "$finalVCFOutDir/all.genotypes.vcf.gz";
$tgt = "$inputVCFFile.tbi.OK";
$dep = "$inputVCFFile.OK";
@cmd = ("$vt index $inputVCFFile");
makeJob($partition, $tgt, $dep, @cmd);

$inputVCFFiles = join(" ", map {"$finalVCFOutDir/$_.sites.vcf.gz"} @CHROM);
$inputVCFFilesOK = join(" ", map {"$finalVCFOutDir/$_.sites.vcf.gz.OK"} @CHROM);
$outputVCFFile = "$finalVCFOutDir/all.sites.vcf.gz";
$tgt = "$outputVCFFile.OK";
$dep = "$inputVCFFilesOK";
@cmd = ("$vt cat $inputVCFFiles -o $outputVCFFile");
makeJob($partition, $tgt, $dep, @cmd);

$inputVCFFile = "$finalVCFOutDir/all.sites.vcf.gz";
$tgt = "$inputVCFFile.tbi.OK";
$dep = "$inputVCFFile.OK";
@cmd = ("$vt index $inputVCFFile");
makeJob($partition, $tgt, $dep, @cmd);

#***********************************
#log end time for concatenating VCFs
#***********************************
my $inputVCFFileIndicesOK = join(" ", map {"$finalVCFOutDir/$_.sites.vcf.gz.tbi.OK"} @CHROM);
$tgt = "$logDir/end.concatenation.normalization.OK";
$dep = "$inputVCFFileIndicesOK";
@cmd = ("date | awk '{print \"end concatenation and normalization: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

#*******************
#Write out make file
#*******************
open(MAK,">$makeFile") || die "Cannot open $makeFile\n";
print MAK ".DELETE_ON_ERROR:\n\n";
print MAK "all: @tgts\n\n";

#clean
push(@tgts, "clean");
push(@deps, "");
push(@cmds, "\t-rm -rf $outputDir/*.* $vcfOutDir/*/*.* $finalVCFOutDir/*.* $logDir/* $outputDir/intervals/*.*");

for(my $i=0; $i < @tgts; ++$i) {
    print MAK "$tgts[$i] : $deps[$i]\n";
    print MAK "$cmds[$i]\n";
}
close MAK;

##########
#Functions
##########

#run a job either locally or by slurm
sub makeJob
{
    my ($method, $tgt, $dep, @cmd) = @_;

    if ($method eq "local")
    {
        makeLocalStep($tgt, $dep, @cmd);
    }
    else
    {
        makeSlurm($partition, $tgt, $dep, @cmd);
    }
}

#run slurm jobs
sub makeSlurm
{
    my ($partition, $tgt, $dep, @cmd) = @_;

    push(@tgts, $tgt);
    push(@deps, $dep);
    my $cmd = "";
    for my $c (@cmd)
    {
        #contains pipe
        if ($c=~/\|/)
        {
            ++$slurmScriptNo;
            my $slurmScriptFile = "$slurmScriptsDir/$slurmScriptNo.sh";
            open(IN, ">$slurmScriptFile");
            print IN "#!/bin/bash\n";
            print IN "set -o pipefail; $c";
            close(IN);
            chmod(0755, $slurmScriptFile);

            $cmd .= "\techo '" . $c . "'\n";
            $cmd .= "\tsrun -p $partition $slurmScriptFile\n";
        }
        else
        {
            $cmd .= "\tsrun -p $partition " . $c . "\n";
        }
    }
    $cmd .= "\ttouch $tgt\n";
    push(@cmds, $cmd);
}

#run a local job
sub makeLocalStep
{
    my ($tgt, $dep, @cmd) = @_;

    push(@tgts, $tgt);
    push(@deps, $dep);
    my $cmd = "";
    for my $c (@cmd)
    {
        $cmd .= "\tset -o pipefail; " . $c . "\n";
    }
    $cmd .= "\ttouch $tgt\n";
    push(@cmds, $cmd);
}

#run a local phony job
sub makePhonyJob
{
    my ($tgt, $dep, @cmd) = @_;

    push(@tgts, $tgt);
    push(@deps, $dep);
    my $cmd = "";
    for my $c (@cmd)
    {
        $cmd .= "\t" . $c . "\n";
    }
    push(@cmds, $cmd);
}