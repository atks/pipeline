#!/usr/bin/perl -w

use warnings;
use strict;
use POSIX;
use Getopt::Long;
use File::Path;
use File::Basename;
use Pod::Usage;

=head1 NAME

generate_vt2_calling_makefile

=head1 SYNOPSIS

 generate_vt2_calling_makefile [options]

  -s     sample file list giving the location of each sample
         column 1: sample name
         column 2: path of bam file
  -r     reference sequence fasta file
  -b     binaries directory : location of binaries required for this pipeline
  -o     output directory : location of all output files
  -d     slurm script sub directory
  -i     switch to generate intermediate files for analyses
  -m     output make file

 example:

=head1 DESCRIPTION

=cut

#option variables
my $help;

#
my $outputDir;
my $slurmScriptsSubDir = "";
my $makeFile = "Makefile";
my $partition = "local";
my $sleep = 0;
my $sampleFile = "";
my $intervalWidth = 20000000;
my $chromosomes;
my $refGenomeFASTAFile = "";
my $generateIntermediateFiles = 1;
my $useDevelopmentVT = 0;
my $useClipOverlap = 0;
my $discoverOptions = "-z -q 20";
my $mergeCandidateVariantsOptions = "";

#initialize options
Getopt::Long::Configure ('bundling');

if(!GetOptions ('h'=>\$help,
                'o:s'=>\$outputDir,
                'd:s'=>\$slurmScriptsSubDir,
                'm:s'=>\$makeFile,
                'p:s'=>\$partition,
                's:s'=>\$sampleFile,
                'w:s'=>\$intervalWidth,
                'c:s'=>\$chromosomes,
                'r:s'=>\$refGenomeFASTAFile,
                'v:s'=>\$discoverOptions,
                'u:s'=>\$useClipOverlap,
                'n:s'=>\$mergeCandidateVariantsOptions,
                'i'=>\$generateIntermediateFiles,
                'x'=>\$useDevelopmentVT
                )
  || !defined($outputDir)
  || !defined($sampleFile)
  || !defined($chromosomes)
  || !defined($refGenomeFASTAFile)
  || scalar(@ARGV)!=0)
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
my $vt = $useDevelopmentVT ? "/net/fantasia/home/atks/dev/vt/vt" : "/net/fantasia/home/atks/programs/vt/vt";
my $samtools = "/net/fantasia/home/atks/programs/samtools/samtools";
my $bam = "/usr/cluster/bin/bam";

printf("generate_vt2_calling_makefile.pl\n");
printf("\n");
printf("options: output dir                         %s\n", $outputDir);
printf("         slurm scripts sub dir              %s\n", $slurmScriptsSubDir);
printf("         make file                          %s\n", $makeFile);
printf("         partition                          %s\n", $partition);
printf("         sample file                        %s\n", $sampleFile);
printf("         interval width                     %s\n", $intervalWidth);
printf("         chromosomes                        %s\n", $chromosomes);
printf("         reference                          %s\n", $refGenomeFASTAFile);
printf("         use clipoverlap                    %s\n", $useClipOverlap);
printf("         discover options                   %s\n", $discoverOptions);
printf("         merge candidate variants options   %s\n", $mergeCandidateVariantsOptions);
printf("         generate intermediate files        %s\n", $generateIntermediateFiles ? "true" : "false");
printf("         use development vt                 %s\n", $useDevelopmentVT ? "true" : "false");
printf("\n");

my @tgts = ();
my @deps = ();
my @cmds = ();
my $tgt;
my $dep;
my @cmd;
my $inputVCFFile;
my $inputVCFFileList;
my $outputVCFFile;
my $processByGenome = ($intervalWidth==0);

mkpath($outputDir);
my $logDir = "$outputDir/log";
mkpath($logDir);
my $auxDir = "$outputDir/aux";
mkpath($auxDir);
my $individualDir = "$outputDir/aux/individual";
mkpath($individualDir);
my $unionDir = "$outputDir/aux/union";
mkpath($unionDir);
my $evaluationDir = "$outputDir/aux/evaluation";
mkpath($evaluationDir);
my $finalDir = "$outputDir/final";
mkpath($finalDir);
my $slurmScriptsDir = "$outputDir/slurm_scripts/$slurmScriptsSubDir";
mkpath($slurmScriptsDir);
my $slurmScriptNo = 0;
my $logFile = "$logDir/run.log";

###########################
#Read samples and BAM paths
########################### 
my %BAMFILE = ();
my @SAMPLE = ();
open(INDEX,"$sampleFile") || die "Cannot open $sampleFile\n";
while (<INDEX>)
{
    s/\r?\n?$//;
    if(!/^#/)
    {
        my ($sampleID, $bamPath) = split('\t', $_);
        $BAMFILE{$sampleID} = $bamPath;
        push(@SAMPLE, $sampleID);
        mkpath("$individualDir/$sampleID");
    }
}
close(INDEX);

###################
#Generate intervals
###################
my %intervalNamesByChrom = ();
my @intervalNames = ();
my @intervals = ();
my @CHROM = ();

my $refGenomeFASTAIndexFile = "$refGenomeFASTAFile.fai";
open(SQ," $refGenomeFASTAIndexFile ") || die "Cannot open  $refGenomeFASTAIndexFile \n";
my %CHROM = ();
map {$CHROM{$_}=1} split(",", $chromosomes);
while (<SQ>)
{
    s/\r?\n?$//;
    if(!/^#/)
    {
        my ($chrom, $len, $rest) = split('\t', $_);

        next if (!exists($CHROM{$chrom}));
        
        print "processing $chrom\t$len ";

        push(@CHROM, $chrom);

        $intervalNamesByChrom{$chrom} = ();
        my $count = 0;
        for my $i (0 .. floor($len/$intervalWidth))
        {
            my $interval = "";
            my $intervalName = "";
            if ($i<floor($len/$intervalWidth))
            {
                $interval = $chrom . ":" . ($intervalWidth*$i+1) . "-" . ($intervalWidth*($i+1));
                $intervalName = $chrom . "_" . ($intervalWidth*$i+1) . "_" . ($intervalWidth*($i+1));
            }
            elsif ($i*$intervalWidth!=$len)
            {
                $interval = $chrom . ":" . ($intervalWidth*$i+1) . "-" . $len;
                $intervalName = $chrom . "_" . ($intervalWidth*$i+1) . "_" . $len;
            }
            else
            {
                last;
            }

            $count++;

            push(@intervals, $interval);
            push(@intervalNames, $intervalName);
            push(@{$intervalNamesByChrom{$chrom}}, $intervalName);
        }

        print "added $count intervals\n";
    }
}
close(SQ);

#############
#1. Discovery
#############

#log start time
$tgt = "$logDir/start.discovery.OK";
$dep = "";
@cmd = "date | awk '{print \"vt calling pipeline\\n\\nstart discovery: \"\$\$0}' > $logFile";
makeLocalStep($tgt, $dep, @cmd);

my @intervalSampleDiscoveryVCFFilesOK = ();

#generate slurm job array script
my $noJobs = scalar(@intervals)*scalar(@SAMPLE);
my $no = 0;
mkpath("$slurmScriptsDir/job_array_output");
my $slurmJobArrayScript = "$slurmScriptsDir/job_array.sh";
open(SCRIPT, ">$slurmJobArrayScript");
print SCRIPT <<SCRIPT;
\#!/bin/bash
\#SBATCH --partition=main,nomosix
\#SBATCH --error=$slurmScriptsDir/job_array_output/%a_%N_%j.err
\#SBATCH --output=$slurmScriptsDir/job_array_output/%a_%N_%j.log
\#SBATCH --job-name=vt_discovery
#\#SBATCH --time=6:0:0
#\#SBATCH --mem=2G
\#SBATCH --cpus-per-task=1
\#SBATCH --array=1-$noJobs
declare -a commands
SCRIPT

#mine variants from aligned reads
for my $i (0 .. $#intervals)
{
    my $intervalVCFFilesOK = "";
    for my $sampleID (@SAMPLE)
    {
        $outputVCFFile = "$individualDir/$sampleID/$intervalNames[$i].sites.bcf";
        $tgt = "$outputVCFFile.OK";
        $dep = "$logDir/start.discovery.OK";
        if ($useClipOverlap)
        {
            @cmd = ("$samtools view -h $BAMFILE{$sampleID} $intervals[$i] -u | $bam clipoverlap --in -.ubam --out -.ubam | $vt discover $discoverOptions -b + -r $refGenomeFASTAFile -s $sampleID -i $intervals[$i] -o $outputVCFFile 2> $individualDir/$sampleID/$intervalNames[$i].discover.log");
        }
        else
        {
            @cmd = ("$vt discover -b $BAMFILE{$sampleID} -r $refGenomeFASTAFile -s $sampleID -i $intervals[$i] -o $outputVCFFile 2> $individualDir/$sampleID/$intervalNames[$i].discover2.log");
        }
        makeJob($partition, $tgt, $dep, @cmd);
        
        #print SCRIPT "commands[" . ++$no . "]= [ ! -e $outputVCFFile.OK ] && $slurmScriptsDir/$slurmScriptNo.sh && touch $outputVCFFile.OK;\n";
        print SCRIPT "commands[" . ++$no . "]= $slurmScriptsDir/$slurmScriptNo.sh && touch $outputVCFFile.OK;\n";
        
        $intervalVCFFilesOK .= " $outputVCFFile.OK";
    }

    push(@intervalSampleDiscoveryVCFFilesOK, $intervalVCFFilesOK);
}

print SCRIPT "bash -c \"\${commands[\${SLURM_ARRAY_TASK_ID}]}\"\n";
close(SCRIPT);

for my $i (0..$#intervals)
{
    $inputVCFFileList = "$unionDir/$intervalNames[$i]_vcf_file.list";
    open(OUT, ">$inputVCFFileList");
    for my $sample (@SAMPLE) {print OUT "$individualDir/$sample/$intervalNames[$i].sites.bcf\n";}
    close(OUT);

    #merge variants and annotate variants
    $outputVCFFile = "$unionDir/$intervalNames[$i].annotated.sites.bcf";
    $tgt = "$outputVCFFile.OK";
    $dep = $intervalSampleDiscoveryVCFFilesOK[$i];
    @cmd = ("$vt merge_candidate_variants $mergeCandidateVariantsOptions -L $inputVCFFileList -o + 2> $unionDir/$intervalNames[$i].merge_candidate_variants.log | " .
            "$vt annotate_indels -r $refGenomeFASTAFile + -o $outputVCFFile 2> $unionDir/$intervalNames[$i].annotate_indels.log");
    makeJob($partition, $tgt, $dep, @cmd);
    
    $inputVCFFile = "$unionDir/$intervalNames[$i].annotated.sites.bcf";
    $tgt = "$inputVCFFile.csi.OK";
    $dep = "$inputVCFFile.OK";
    @cmd = ("$vt index $inputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);

#    #consolidate vntrs and multiallelics
#    $inputVCFFile = "$unionDir/$intervalNames[$i].annotated.sites.bcf";
#    $outputVCFFile = "$unionDir/$intervalNames[$i].sites.bcf";
#    $tgt = "$outputVCFFile.OK";
#    $dep = "$inputVCFFile.OK";
#    @cmd = ("$vt consolidate_vntrs $inputVCFFile -o + 2> $unionDir/$intervalNames[$i].consolidate_vntrs.log | " .
#            "$vt consolidate + -o $outputVCFFile 2> $unionDir/$intervalNames[$i].consolidate.log");
#    makeJob($partition, $tgt, $dep, @cmd);
#    
#    $inputVCFFile = "$unionDir/$intervalNames[$i].sites.bcf";
#    $tgt = "$inputVCFFile.csi.OK";
#    $dep = "$inputVCFFile.OK";
#    @cmd = ("$vt index $inputVCFFile");
#    makeJob($partition, $tgt, $dep, @cmd);

}

##################################
#Intermediate files for inspection
##################################    
if ($generateIntermediateFiles)
{
    #concatenate annotated candidate variant lists
    $inputVCFFileList = "$unionDir/candidates_vcf_file.list";
    open(OUT, ">$inputVCFFileList");
    for my $intervalName (@intervalNames) {print OUT "$unionDir/$intervalName.annotated.sites.bcf\n"; }
    close(OUT);
    
    $outputVCFFile = "$evaluationDir/all.discovery.sites.bcf";
    $tgt = "$outputVCFFile.OK";
    $dep = join(" ", map {"$unionDir/$_.annotated.sites.bcf.OK"} @intervalNames);
    @cmd = ("$vt cat -L $inputVCFFileList -o $outputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);
    
    $inputVCFFile = "$evaluationDir/all.discovery.sites.bcf";
    $tgt = "$inputVCFFile.csi.OK";
    $dep = "$inputVCFFile.OK";
    @cmd = ("$vt index $inputVCFFile");
    makeJob($partition, $tgt, $dep, @cmd);  
}


#log end time
$tgt = "$logDir/end.discovery.OK";
$dep = join(" ", map {"$unionDir/$_.annotated.sites.bcf.OK"} @intervalNames);
@cmd = ("date | awk '{print \"end discovery: \"\$\$0}' >> $logFile");
makeJob("local", $tgt, $dep, @cmd);

###############
##2. Genotyping
###############
#
#my @intervalSampleGenotypingVCFFilesOK = ();
#
##mine variants from aligned reads
#for my $i (0 .. $#intervals)
#{
#    my $intervalVCFFilesOK = "";
#    for my $sampleID (@SAMPLE)
#    {
#        $inputVCFFile = "$unionDir/$intervalNames[$i].annotated.sites.bcf";
#        $outputVCFFile = "$individualDir/$sampleID/$intervalNames[$i].genotypes.bcf";
#        $tgt = "$outputVCFFile.OK";
#        $dep = "$inputVCFFile.OK";
#        @cmd = ("$vt genotype2 $inputVCFFile -b $BAMFILE{$sampleID} -r $refGenomeFASTAFile -s $sampleID -i $intervals[$i] -o $outputVCFFile 2> $individualDir/$sampleID/$intervalNames[$i].genotype2.log");
##        @cmd = ("[ ! -e $logDir/start.genotyping.OK ] && touch $logDir/start.genotyping.OK && date | awk '{print \"start genotyping: \"\$\$0}' >> $logFile\n" .
##                "\t$vt genotype2 $inputVCFFile -b $BAMFILE{$sampleID} -r $refGenomeFASTAFile -s $sampleID -i $intervals[$i] -o $outputVCFFile 2> $individualDir/$sampleID/$intervalNames[$i].genotype2.log");
#        makeJob($partition, $tgt, $dep, @cmd);
#
#        $inputVCFFile = "$individualDir/$sampleID/$intervalNames[$i].genotypes.bcf";
#        $tgt = "$inputVCFFile.csi.OK";
#        $dep = "$inputVCFFile.OK";
#        @cmd = ("$vt index $inputVCFFile");
#        makeJob($partition, $tgt, $dep, @cmd);
#
#        $intervalVCFFilesOK .= " $outputVCFFile.OK";
#    }
#
#    push(@intervalSampleGenotypingVCFFilesOK, $intervalVCFFilesOK);
#}
#
#my $intervalSampleGenotypingVCFFiles = join(" ", @intervalSampleGenotypingVCFFilesOK);
#
##log end time
#$tgt = "$logDir/end.genotyping.OK";
#$dep = $intervalSampleGenotypingVCFFiles;
#@cmd = ("date | awk '{print \"end genotyping: \"\$\$0}' >> $logFile");
#makeJob("local", $tgt, $dep, @cmd);

#####################
#3. Consolidate files
#####################

#$inputVCFFileList = "$unionDir/genotypes_vcf_file.list";
#open(OUT, ">$inputVCFFileList");
#for my $intervalName (@intervalNames) {print OUT "$individualDir/$SAMPLE[0]/$intervalName.genotypes.bcf\n"; }
#close(OUT);
#
#$outputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#$tgt = "$outputVCFFile.OK";
#$dep = join(" ", map {"$individualDir/$SAMPLE[0]/$_.genotypes.bcf.OK"} @intervalNames);
#@cmd = ("$vt cat -L $inputVCFFileList -o $outputVCFFile");
#makeJob($partition, $tgt, $dep, @cmd);
#
#$inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#$tgt = "$inputVCFFile.csi.OK";
#$dep = "$inputVCFFile.OK";
#@cmd = ("$vt index $inputVCFFile");
#makeJob($partition, $tgt, $dep, @cmd);
#
#$inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#my $outputFile = "$evaluationDir/profile_na12878.snps.txt";
#$tgt = "$outputFile.OK";
#$dep = "$inputVCFFile.csi.OK";
#@cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.snps.reference.txt  -r ~/ref/genome/hs37d5.fa  -f \"VTYPE==SNP\" 2> $outputFile");
#makeJob($partition, $tgt, $dep, @cmd);
#
#$inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#$outputFile = "$evaluationDir/profile_na12878.indels.txt";
#$tgt = "$outputFile.OK";
#$dep = "$inputVCFFile.csi.OK";
#@cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.indels.reference.txt  -r ~/ref/genome/hs37d5.fa  -f \"VTYPE==INDEL\" 2> $outputFile");
#makeJob($partition, $tgt, $dep, @cmd);

##################################
#Intermediate files for inspection
###################################    
#if ($generateIntermediateFiles)
#{
#    if (scalar(@SAMPLE)==1)
#    {
#        if (scalar(@CHROM)!=1)
#        {
#            $inputVCFFileList = "$unionDir/genotypes_vcf_file.list";
#            open(OUT, ">$inputVCFFileList");
#            for my $intervalName (@intervalNames) {print OUT "$individualDir/$SAMPLE[0]/$intervalName.genotypes.bcf\n"; }
#            close(OUT);
#            
#            $outputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#            $tgt = "$outputVCFFile.OK";
#            $dep = join(" ", map {"$individualDir/$SAMPLE[0]/$_.genotypes.bcf.OK"} @intervalNames);
#            @cmd = ("$vt cat -L $inputVCFFileList -o $outputVCFFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#            $tgt = "$inputVCFFile.csi.OK";
#            $dep = "$inputVCFFile.OK";
#            @cmd = ("$vt index $inputVCFFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#            my $outputFile = "$evaluationDir/profile_na12878.snps.txt";
#            $tgt = "$outputFile.OK";
#            $dep = "$inputVCFFile.csi.OK";
#            @cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.snps.reference.txt  -r ~/ref/genome/hs37d5.fa  -f \"VTYPE==SNP\" 2> $outputFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$SAMPLE[0].genotypes.bcf";
#            $outputFile = "$evaluationDir/profile_na12878.indels.txt";
#            $tgt = "$outputFile.OK";
#            $dep = "$inputVCFFile.csi.OK";
#            @cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.indels.reference.txt  -r ~/ref/genome/hs37d5.fa  -f \"VTYPE==INDEL\" 2> $outputFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#        }
#        else
#        {
#            $inputVCFFileList = "$unionDir/genotypes_vcf_file.list";
#            open(OUT, ">$inputVCFFileList");
#            for my $intervalName (@intervalNames) {print OUT "$individualDir/$SAMPLE[0]/$intervalName.genotypes.bcf\n"; }
#            close(OUT);
#            
#            $outputVCFFile = "$evaluationDir/$CHROM[0].$SAMPLE[0].genotypes.bcf";
#            $tgt = "$outputVCFFile.OK";
#            $dep = join(" ", map {"$individualDir/$SAMPLE[0]/$_.genotypes.bcf.OK"} @intervalNames);
#            @cmd = ("$vt cat -L $inputVCFFileList -o $outputVCFFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$CHROM[0].$SAMPLE[0].genotypes.bcf";
#            $tgt = "$inputVCFFile.csi.OK";
#            $dep = "$inputVCFFile.OK";
#            @cmd = ("$vt index $inputVCFFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$CHROM[0].$SAMPLE[0].genotypes.bcf";
#            my $outputFile = "$evaluationDir/$CHROM[0].profile_na12878.snps.txt";
#            $tgt = "$outputFile.OK";
#            $dep = "$inputVCFFile.csi.OK";
#            @cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.snps.reference.txt  -r ~/ref/genome/hs37d5.fa -i $CHROM[0] -f \"VTYPE==SNP\" 2> $outputFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#            
#            $inputVCFFile = "$evaluationDir/$CHROM[0].$SAMPLE[0].genotypes.bcf";
#            $outputFile = "$evaluationDir/$CHROM[0].profile_na12878.indels.txt";
#            $tgt = "$outputFile.OK";
#            $dep = "$inputVCFFile.csi.OK";
#            @cmd = ("$vt profile_na12878 $inputVCFFile -g /net/fantasia/home/atks/ref/vt/grch37/NA12878.indels.reference.txt  -r ~/ref/genome/hs37d5.fa -i $CHROM[0] -f \"VTYPE==INDEL\"  2> $outputFile");
#            makeJob($partition, $tgt, $dep, @cmd);
#        }
#    }
#}

####################
#Write out make file
####################

open(MAK,">$makeFile") || die "Cannot open $makeFile\n";
print MAK ".DELETE_ON_ERROR:\n\n";
print MAK ".PHONY: clean\n\n";
print MAK "all: @tgts\n\n";

#clean
$tgt = "clean";
$dep = "";
@cmd = ("-rm -rf $finalDir/*.OK $individualDir/*.OK $individualDir/*/*.OK $logDir/*.OK");
makePhonyJob($tgt, $dep, @cmd);

for(my $i=0; $i < @tgts; ++$i)
{
    print MAK "$tgts[$i]: $deps[$i]\n";
    print MAK "$cmds[$i]\n";
}
close MAK;

##########
#functions
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