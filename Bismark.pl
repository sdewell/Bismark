#!/usr/bin/perl --
use strict;
use warnings;
use IO::Handle;
use Cwd;
$|++;
use Getopt::Long;

my $parent_dir = getcwd;

### before processing the command line we will replace --solexa1.3-quals with --phred64-quals as the . in the option name will cause Getopt::Long to fail
foreach my $arg (@ARGV){
  if ($arg eq '--solexa1.3-quals'){
    $arg = '--phred64-quals';
  }
}
my @filenames;   # will be populated by processing the command line

my ($genome_folder,$CT_index_basename,$GA_index_basename,$path_to_bowtie,$sequence_file_format,$bowtie_options) = process_command_line();

my @fhs;         # stores alignment process names, bisulfite index location, bowtie filehandles and the number of times sequences produced an alignment
my %chromosomes; # stores the chromosome sequences of the mouse genome
my %counting;    # counting various events

foreach my $filename (@filenames){
  chdir $parent_dir or die "Unable to move to initial working directory $!\n";
  ### resetting the counting hash and fhs
  reset_counters_and_fhs();

  ### PAIRED-END ALIGNMENTS
  if ($filename =~ ','){
    my ($C_to_T_infile_1,$G_to_A_infile_1); # to be made from mate1 file
    $fhs[0]->{name} = 'CTread1GAread2CTgenome';
    $fhs[1]->{name} = 'GAread1CTread2GAgenome';
    $fhs[2]->{name} = 'GAread1CTread2CTgenome';
    $fhs[3]->{name} = 'CTread1GAread2GAgenome';
    print "\nPaired-end alignments will be performed\n",'='x39,"\n\n";

    my ($filename_1,$filename_2) = (split (",",$filename));
    print "The provided filenames for paired-end alignments are $filename_1 and $filename_2\n";

    ### additional variables only for paired-end alignments
    my ($C_to_T_infile_2,$G_to_A_infile_2); # to be made from mate2 file

    ### FastA format
    if ($sequence_file_format eq 'FASTA'){
      print "Input files are in FastA format\n";
      ($C_to_T_infile_1,$G_to_A_infile_1) = biTransformFastAFiles ($filename_1);
      ($C_to_T_infile_2,$G_to_A_infile_2) = biTransformFastAFiles ($filename_2);

      $fhs[0]->{inputfile_1} = $C_to_T_infile_1;
      $fhs[0]->{inputfile_2} = $G_to_A_infile_2;
      $fhs[1]->{inputfile_1} = $G_to_A_infile_1;
      $fhs[1]->{inputfile_2} = $C_to_T_infile_2;
      $fhs[2]->{inputfile_1} = $G_to_A_infile_1;
      $fhs[2]->{inputfile_2} = $C_to_T_infile_2;
      $fhs[3]->{inputfile_1} = $C_to_T_infile_1;
      $fhs[3]->{inputfile_2} = $G_to_A_infile_2;

      paired_end_align_fragments_to_bisulfite_genome_fastA ($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
    }

    ### FastQ format
    else{
      print "Input files are in FastQ format\n";
      ($C_to_T_infile_1,$G_to_A_infile_1) = biTransformFastQFiles ($filename_1);
      ($C_to_T_infile_2,$G_to_A_infile_2) = biTransformFastQFiles ($filename_2);

      $fhs[0]->{inputfile_1} = $C_to_T_infile_1;
      $fhs[0]->{inputfile_2} = $G_to_A_infile_2;
      $fhs[1]->{inputfile_1} = $G_to_A_infile_1;
      $fhs[1]->{inputfile_2} = $C_to_T_infile_2;
      $fhs[2]->{inputfile_1} = $G_to_A_infile_1;
      $fhs[2]->{inputfile_2} = $C_to_T_infile_2;
      $fhs[3]->{inputfile_1} = $C_to_T_infile_1;
      $fhs[3]->{inputfile_2} = $G_to_A_infile_2;

      paired_end_align_fragments_to_bisulfite_genome_fastQ ($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
    }
    start_methylation_call_procedure_paired_ends($filename_1,$filename_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
  }

  ### Else we are performing SINGLE-END ALIGNMENTS
  else{
    print "\nSingle-end alignments will be performed\n",'='x39,"\n\n";
    ### Initialising bisulfite conversion filenames
    my ($C_to_T_infile,$G_to_A_infile);


    ### FastA format
    if ($sequence_file_format eq 'FASTA'){
      print "Inut file is in FastA format\n";
      ($C_to_T_infile,$G_to_A_infile) = biTransformFastAFiles ($filename);

      $fhs[0]->{inputfile} = $fhs[1]->{inputfile} = $C_to_T_infile;
      $fhs[2]->{inputfile} = $fhs[3]->{inputfile} = $G_to_A_infile;

      ### Creating 4 different bowtie filehandles and storing the first entry
      single_end_align_fragments_to_bisulfite_genome_fastA ($C_to_T_infile,$G_to_A_infile);
    }

    ## FastQ format
    else{
      print "Input file is in FastQ format\n";
      ($C_to_T_infile,$G_to_A_infile) = biTransformFastQFiles ($filename);
      $fhs[0]->{inputfile} = $fhs[1]->{inputfile} = $C_to_T_infile;
      $fhs[2]->{inputfile} = $fhs[3]->{inputfile} = $G_to_A_infile;

      ### Creating 4 different bowtie filehandles and storing the first entry
      single_end_align_fragments_to_bisulfite_genome_fastQ ($C_to_T_infile,$G_to_A_infile);
    }
    start_methylation_call_procedure_single_ends($filename,$C_to_T_infile,$G_to_A_infile);
  }
}

sub start_methylation_call_procedure_single_ends {
  my ($sequence_file,$C_to_T_infile,$G_to_A_infile) = @_;

  ### printing all alignments to a results file
  my $outfile = $sequence_file;
  $outfile =~ s/^/Bismark_mapping_results_/;
  print "Writing bisulfite mapping results to $outfile\n\n";
  open (OUT,'>',$outfile) or die "Failed to write to $outfile: $!\n";

  ### printing alignment and methylation call summary to a report file
  my $reportfile = $sequence_file;
  $reportfile =~ s/^/Bismark_report_/;
  open (REPORT,'>',$reportfile) or die "Failed to write to $outfile: $!\n";
  print REPORT "Bismark report for: $sequence_file\n\n";

  ### if 2 or more files are provided we might still hold the genome in memory and don't need to read it in a second time
  unless (%chromosomes){
    my $cwd = getcwd; # storing the path of the current working directory
    print "Current working directory is: $cwd\n\n";
    read_genome_into_memory($cwd);
  }
  ### Input file is in FastA format
  if ($sequence_file_format eq 'FASTA'){
    process_single_end_fastA_file_for_methylation_call($sequence_file,$C_to_T_infile,$G_to_A_infile);
  }
  ### Input file is in FastQ format
  else{
    process_single_end_fastQ_file_for_methylation_call($sequence_file,$C_to_T_infile,$G_to_A_infile);
  }
}

sub start_methylation_call_procedure_paired_ends {
  my ($sequence_file_1,$sequence_file_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;

  ### printing all alignments to a results file
  my $outfile = $sequence_file_1;
  $outfile =~ s/^/Bismark_paired-end_mapping_results_/;
  print "Writing bisulfite mapping results to $outfile\n\n";
  open (OUT,'>',$outfile) or die "Failed to write to $outfile: $!";

  ### printing alignment and methylation call summary to a report file
  my $reportfile = $sequence_file_1;
  $reportfile =~ s/^/Bismark_report_/;
  open (REPORT,'>',$reportfile) or die "Failed to write to $outfile: $!\n";
  print REPORT "Bismark report for: $sequence_file_1 and $sequence_file_2\n\n";

  ### if 2 or more files are provided we might still hold the genome in memory and don't need to read it in a second time
  unless (%chromosomes){
    my $cwd = getcwd; # storing the path of the current working directory
    print "Current working directory is: $cwd\n\n";
    read_genome_into_memory($cwd);
  }
  ### Input files are in FastA format
  if ($sequence_file_format eq 'FASTA'){
    process_fastA_files_for_paired_end_methylation_calls($sequence_file_1,$sequence_file_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
  }
  ### Input files are in FastQ format
  else{
    process_fastQ_files_for_paired_end_methylation_calls($sequence_file_1,$sequence_file_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
  }
}

sub print_final_analysis_report_single_end{
  my ($C_to_T_infile,$G_to_A_infile) = @_;
  ### All sequences from the original sequence file have been analysed now
  ### deleting temporary C->T or G->A infiles
  my $deletion_successful =  unlink $C_to_T_infile,$G_to_A_infile;
  if ($deletion_successful == 2){
    warn "\nSuccessfully deleted the temporary files $C_to_T_infile and $G_to_A_infile\n\n";
  }
  else{
    warn "Could not delete temporary files properly $!\n";
  }

  ### printing a final report for the alignment procedure
  print REPORT "Final Alignment report\n",'='x22,"\n";
  warn "Final Alignment report\n",'='x22,"\n";
  foreach my $index (0..$#fhs){
    print "$fhs[$index]->{name}\n";
    print "$fhs[$index]->{seen}\talignments on the correct strand in total\n";
    print "$fhs[$index]->{wrong_strand}\talignments were discarded (nonsensical alignments)\n\n";
  }

  ### printing a final report for the methylation call procedure
  warn "Sequences analysed in total:\t$counting{sequences_count}\n";
  print REPORT "Sequences analysed in total:\t$counting{sequences_count}\n";

  my $percent_alignable_sequences = sprintf ("%.1f",$counting{unique_best_alignment_count}*100/$counting{sequences_count});
  print REPORT "Number of alignments with a unique best hit from the different alignments:\t$counting{unique_best_alignment_count}\t(${percent_alignable_sequences}%) \n";
  ### percentage of low complexity reads overruled because of low complexity (thereby creating a bias for highly methylated reads),
  ### only calculating the percentage if there were any overruled alignments
  if ($counting{low_complexity_alignments_overruled_count}){
    my $percent_overruled_low_complexity_alignments = sprintf ("%.1f",$counting{low_complexity_alignments_overruled_count}*100/$counting{sequences_count});
    print REPORT "Number of low complexity alignments which were overruled to have a unique best hit rather than discarding them:\t$counting{low_complexity_alignments_overruled_count}\t(${percent_overruled_low_complexity_alignments}%)\n";
  }
  print REPORT "Sequence with no single alignment under any condition:\t$counting{no_single_alignment_found}\n";
  print REPORT "Sequences did not map uniquely:\t$counting{unsuitable_sequence_count}\n\n";
  print REPORT "Number of sequences with unique best (first) alignment came from the bowtie output:\n";
  print REPORT join ("\n","CT/CT:\t$counting{CT_CT_count}\t((converted) top strand)","CT/GA:\t$counting{CT_GA_count}\t((converted) bottom strand)","GA/CT:\t$counting{GA_CT_count}\t(complementary to (converted) top strand)","GA/GA:\t$counting{GA_GA_count}\t(complementary to (converted) bottom strand)"),"\n\n";

  ### detailed information about Cs analysed
  warn "Final Cytosine Methylation Report\n",'='x33,"\n";
  my $total_number_of_C = $counting{total_meC_count}+$counting{total_meCpG_count}+$counting{total_unmethylated_C_count}+$counting{total_unmethylated_CpG_count};
  warn "Total number of C's analysed:\t$total_number_of_C\n";
  warn "Total methylated C's in non-CpG context:\t$counting{total_meC_count}\n";
  warn "Total methylated C's in CpG context:\t $counting{total_meCpG_count}\n";
  warn "Total C to T conversions in non-CpG context:\t$counting{total_unmethylated_C_count}\n";
  warn "Total C to T conversions in CpG context:\t$counting{total_unmethylated_CpG_count}\n\n";

  print REPORT "Final Cytosine Methylation Report\n",'='x33,"\n";
  print REPORT "Total number of C's analysed:\t$total_number_of_C\n";
  print REPORT "Total methylated C's in non-CpG context:\t$counting{total_meC_count}\n";
  print REPORT "Total methylated C's in CpG context:\t $counting{total_meCpG_count}\n";
  print REPORT "Total C to T conversions in non-CpG context:\t$counting{total_unmethylated_C_count}\n";
  print REPORT "Total C to T conversions in CpG context:\t$counting{total_unmethylated_CpG_count}\n\n";


 my $percent_meC;
  if (($counting{total_meC_count}+$counting{total_unmethylated_C_count}) > 0){
    $percent_meC = sprintf("%.1f",100*$counting{total_meC_count}/($counting{total_meC_count}+$counting{total_unmethylated_C_count}));
  }
  my $percent_meCpG;
  if (($counting{total_meCpG_count}+$counting{total_unmethylated_CpG_count}) > 0){
    $percent_meCpG = sprintf("%.1f",100*$counting{total_meCpG_count}/($counting{total_meCpG_count}+$counting{total_unmethylated_CpG_count}));
  }
  ### calculating methylated C percentage (non CpG context) if applicable
  if ($percent_meC){
    warn "C methylated but not in CpG context:\t${percent_meC}%\n";
    print REPORT "C methylated but not in CpG context:\t${percent_meC}%\n";
  }
  else{
    warn "Can't determine percentage of methylated Cs (not in CpG context) if value was 0\n";
    print REPORT "Can't determine percentage of methylated Cs (not in CpG context) if value was 0\n";
  }
  ### calculating methylated CpG percentage if applicable
  if ($percent_meCpG){
    warn "C methylated in CpG context:\t${percent_meCpG}%\n";
    print REPORT "C methylated in CpG context:\t${percent_meCpG}%\n";
  }
  else{
    warn "Can't determine percentage of methylated Cs (in CpG context) if value was 0\n";
    print REPORT "Can't determine percentage of methylated Cs (in CpG context) if value was 0\n";
  }
}

sub print_final_analysis_report_paired_ends{
  my ($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;
  ### All sequences from the original sequence file have been analysed now
  ### deleting temporary C->T or G->A infiles
  my $deletion_successful =  unlink $C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2;
  if ($deletion_successful == 4){
    warn "\nSuccessfully deleted the temporary files $C_to_T_infile_1, $G_to_A_infile_1, $C_to_T_infile_2 and $G_to_A_infile_2\n\n";
  }
  else{
    warn "Could not delete temporary files properly: $!\n";
  }

  ### printing a final report for the alignment procedure
  warn "Final Alignment report\n",'='x22,"\n";
  print REPORT "Final Alignment report\n",'='x22,"\n";
  foreach my $index (0..$#fhs){
    print "$fhs[$index]->{name}\n";
    print "$fhs[$index]->{seen}\talignments on the correct strand in total\n";
    print "$fhs[$index]->{wrong_strand}\talignments were discarded (nonsensical alignments)\n\n";
  }
  ### printing a final report for the methylation call procedure
  print "Sequences analysed in total:\t$counting{sequences_count}\n";
  my $percent_alignable_sequence_pairs = sprintf ("%.1f",$counting{unique_best_alignment_count}*100/$counting{sequences_count});
  print "Number of paired-end alignments with a unique best hit:\t$counting{unique_best_alignment_count}\t(${percent_alignable_sequence_pairs}%) \n";
  print "Sequence with no single alignment under any condition:\t$counting{no_single_alignment_found}\n";
  print "Sequences did not map uniquely:\t$counting{unsuitable_sequence_count}\n\n";
  print "Number of sequences with unique best (first) alignment came from the bowtie output:\n";
  print join ("\n","CT/GA/CT:\t$counting{CT_GA_CT_count}\t((converted) top strand)","GA/CT/GA:\t$counting{GA_CT_GA_count}\t((converted) bottom strand)","GA/CT/CT:\t$counting{GA_CT_CT_count}\t(complementary to (converted) top strand)","CT/GA/GA:\t$counting{CT_GA_GA_count}\t(complementary to (converted) bottom strand)"),"\n\n";
  ### detailed information about Cs analysed
  warn "Final Cytosine Methylation Report\n",'='x33,"\n";
  print REPORT "Final Cytosine Methylation Report\n",'='x33,"\n";
  my $total_number_of_C = $counting{total_meC_count}+$counting{total_meCpG_count}+$counting{total_unmethylated_C_count}+$counting{total_unmethylated_CpG_count};
  warn "Total number of C's analysed:\t$total_number_of_C\n";
  warn "Total methylated C's in non-CpG context:\t$counting{total_meC_count}\n";
  warn "Total methylated C's in CpG context:\t $counting{total_meCpG_count}\n";
  warn "Total C to T conversions in non-CpG context:\t$counting{total_unmethylated_C_count}\n";
  warn "Total C to T conversions in CpG context:\t$counting{total_unmethylated_CpG_count}\n\n";

  print REPORT "Total number of C's analysed:\t$total_number_of_C\n";
  print REPORT "Total methylated C's in non-CpG context:\t$counting{total_meC_count}\n";
  print REPORT "Total methylated C's in CpG context:\t $counting{total_meCpG_count}\n";
  print REPORT "Total C to T conversions in non-CpG context:\t$counting{total_unmethylated_C_count}\n";
  print REPORT "Total C to T conversions in CpG context:\t$counting{total_unmethylated_CpG_count}\n\n";
  my $percent_meC;
  if (($counting{total_meC_count}+$counting{total_unmethylated_C_count}) > 0){
    $percent_meC = sprintf("%.1f",100*$counting{total_meC_count}/($counting{total_meC_count}+$counting{total_unmethylated_C_count}));
  }
  my $percent_meCpG;
  if (($counting{total_meCpG_count}+$counting{total_unmethylated_CpG_count}) > 0){
    $percent_meCpG = sprintf("%.1f",100*$counting{total_meCpG_count}/($counting{total_meCpG_count}+$counting{total_unmethylated_CpG_count}));
  }
  ### calculating methylated C percentage (non CpG context) if applicable
  if ($percent_meC){
    warn "C methylated but not in CpG context:\t${percent_meC}%\n";
    print REPORT "C methylated but not in CpG context:\t${percent_meC}%\n";
  }
  else{
    warn "Can't determine percentage of methylated Cs (not in CpG context) if value was 0\n";
    print REPORT "Can't determine percentage of methylated Cs (not in CpG context) if value was 0\n";
  }
  ### calculating methylated CpG percentage if applicable
  if ($percent_meCpG){
    warn "C methylated in CpG context:\t${percent_meCpG}%\n";
    print REPORT "C methylated in CpG context:\t${percent_meCpG}%\n";
  }
  else{
    warn "Can't determine percentage of methylated Cs (in CpG context) if value was 0\n";
    print REPORT "Can't determine percentage of methylated Cs (in CpG context) if value was 0\n";
  }
}

sub process_single_end_fastA_file_for_methylation_call{
  my ($sequence_file,$C_to_T_infile,$G_to_A_infile) = @_;
  ### this is a FastA sequence file; we need the actual sequence to compare it against the genomic sequence in order to make a methylation call.
  ### Now reading in the sequence file sequence by sequence and see if the current sequence was mapped to one (or both) of the converted genomes in either
  ### the C->T or G->A version
  open (IN,$sequence_file) or die $!;
  warn "\nReading in the sequence file $sequence_file\n";
  while (1) {
    # last if ($counting{sequences_count} > 100);
    my $identifier = <IN>;
    my $sequence = <IN>;
    last unless ($identifier and $sequence);
    $counting{sequences_count}++;
    if ($counting{sequences_count}%100000==0) {
      warn "Processed $counting{sequences_count} sequences so far\n";
    }
    chomp $sequence;
    chomp $identifier;
    $identifier =~ s/^>//; # deletes the > at the beginning of FastA headers
    check_bowtie_results_single_end(uc$sequence,$identifier);
  }
  print "Processed $counting{sequences_count} sequences in total\n\n";
  close IN or die "Failed to close filehandle $!";
  print_final_analysis_report_single_end($C_to_T_infile,$G_to_A_infile);
}

sub process_single_end_fastQ_file_for_methylation_call{
  my ($sequence_file,$C_to_T_infile,$G_to_A_infile) = @_;
  ### this is the Illumina sequence file; we need the actual sequence to compare it against the genomic sequence in order to make a methylation call.
  ### Now reading in the sequence file sequence by sequence and see if the current sequence was mapped to one (or both) of the converted genomes in either
  ### the C->T or G->A version
  open (IN,$sequence_file) or die $!;
  warn "\nReading in the sequence file $sequence_file\n";
  while (1) {
    #last if ($counting{sequences_count} > 100);
    my $identifier = <IN>;
    my $sequence = <IN>;
    my $identifier_2 = <IN>;
    my $quality_value = <IN>;
    last unless ($identifier and $sequence and $identifier_2 and $quality_value);
    $counting{sequences_count}++;
    if ($counting{sequences_count}%1000000==0) {
      warn "Processed $counting{sequences_count} sequences so far\n";
    }
    chomp $sequence;
    chomp $identifier;
    $identifier =~ s/^\@//;	# deletes the @ at the beginning of Illumin FastQ headers
    check_bowtie_results_single_end(uc$sequence,$identifier);
  }
  print "Processed $counting{sequences_count} sequences in total\n\n";
  close IN or die "Failed to close filehandle $!";
  print_final_analysis_report_single_end($C_to_T_infile,$G_to_A_infile);
}

sub process_fastA_files_for_paired_end_methylation_calls{
  my ($sequence_file_1,$sequence_file_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;
  ### Processing the two FastA sequence files; we need the actual sequences of both reads to compare them against the genomic sequence in order to
  ### make a methylation call. The sequence idetifier per definition needs to be the same for a sequence pair used for paired-end mapping.
  ### Now reading in the sequence files sequence by sequence and see if the current sequences produced an alignment to one (or both) of the
  ### converted genomes (either the C->T or G->A version)
  open (IN1,$sequence_file_1) or die $!;
  open (IN2,$sequence_file_2) or die $!;
  warn "\nReading in the sequence files $sequence_file_1 and $sequence_file_2\n";
  ### Both files are required to have the exact same number of sequences, therefore we can process the sequences jointly one by one
  while (1) {
    # reading from the first input file
    my $identifier_1 = <IN1>;
    my $sequence_1 = <IN1>;
    # reading from the second input file
    my $identifier_2 = <IN2>;
    my $sequence_2 = <IN2>;
    last unless ($identifier_1 and $sequence_1 and $identifier_2 and $sequence_2);
    $counting{sequences_count}++;
    if ($counting{sequences_count}%100000==0) {
      warn "Processed $counting{sequences_count} sequences so far\n";
    }
    chomp $sequence_1;
    chomp $identifier_1;
    chomp $sequence_2;
    chomp $identifier_2;
    $identifier_1 =~ s/^>//; # deletes the > at the beginning of FastA headers
    $identifier_2 =~ s/^>//;
    $identifier_1 =~ s/\/[12]//; # deletes the 1/2 at the end
    $identifier_2 =~ s/\/[12]//;
    if ($identifier_1 eq $identifier_2){
      check_bowtie_results_paired_ends(uc$sequence_1,uc$sequence_2,$identifier_1);
    }
    else {
      die "Sequence IDs are not identical\n";
    }
  }
  print "Processed $counting{sequences_count} sequences in total\n\n";
  close IN1 or die "Failed to close filehandle $!";
  close IN2 or die "Failed to close filehandle $!";
  print_final_analysis_report_paired_ends($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
}

sub process_fastQ_files_for_paired_end_methylation_calls{
  my ($sequence_file_1,$sequence_file_2,$C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;
  ### Processing the two Illumina sequence files; we need the actual sequence of both reads to compare them against the genomic sequence in order to
  ### make a methylation call. The sequence identifier per definition needs to be same for a sequence pair used for paired-end alignments.
  ### Now reading in the sequence files sequence by sequence and see if the current sequences produced a paired-end alignment to one (or both)
  ### of the converted genomes (either C->T or G->A version)
  open (IN1,$sequence_file_1) or die $!;
  open (IN2,$sequence_file_2) or die $!;
  warn "\nReading in the sequence files $sequence_file_1 and $sequence_file_2\n";
  ### Both files are required to have the exact same number of sequences, therefore we can process the sequences jointly one by one
  while (1) {
    # reading from the first input file
    my $identifier_1 = <IN1>;
    my $sequence_1 = <IN1>;
    my $ident_1 = <IN1>;         # not needed
    my $quality_value_1 = <IN1>; # not needed
    # reading from the second input file
    my $identifier_2 = <IN2>;
    my $sequence_2 = <IN2>;
    my $ident_2 = <IN2>;         # not needed
    my $quality_value_2 = <IN2>; # not needed
    last unless ($identifier_1 and $sequence_1 and $quality_value_1 and $identifier_2 and $sequence_2 and $quality_value_2);
    $counting{sequences_count}++;
    if ($counting{sequences_count}%100000==0) {
      warn "Processed $counting{sequences_count} sequences so far\n";
    }
    #   last if ($counting{sequences_count} >100);
    chomp $sequence_1;
    chomp $identifier_1;
    chomp $sequence_2;
    chomp $identifier_2;
    $identifier_1 =~ s/^\@//;	 # deletes the @ at the beginning of Illumin FastQ headers
    $identifier_2 =~ s/^\@//;
    $identifier_1 =~ s/\/[12]//; # deletes the 1/2 at the end
    $identifier_2 =~ s/\/[12]//;
    if ($identifier_1 eq $identifier_2){
      check_bowtie_results_paired_ends(uc$sequence_1,uc$sequence_2,$identifier_1);
    }
    else {
      print "$identifier_1\t$identifier_2\n";
      die "Sequence IDs are not identical\n $!";
    }
  }
  print "Processed $counting{sequences_count} sequences in total\n\n";
  close IN1 or die "Failed to close filehandle $!";
  close IN2 or die "Failed to close filehandle $!";
  print_final_analysis_report_paired_ends($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2);
}

sub check_bowtie_results_single_end{
  my ($sequence,$identifier) = @_;
  my %mismatches = ();
  ### reading from the bowtie output files to see if this sequence aligned to a bisulfite converted genome
  foreach my $index (0..$#fhs){
    ### skipping this index if the last alignment has been set to undefined already (i.e. end of bowtie output)
    next unless ($fhs[$index]->{last_line} and $fhs[$index]->{last_seq_id});
    ### if the sequence we are currently looking at produced an alignment we are doing various things with it
    if ($fhs[$index]->{last_seq_id} eq $identifier) {
      ###############################################################
      ### STEP I Now processing the alignment stored in last_line ###
      ###############################################################
      my $valid_alignment_found_1 = decide_whether_single_end_alignment_is_valid($index,$identifier);
      ### sequences can fail at this point if there was only 1 seq in the wrong orientation, or if there were 2 seqs, both in the wrong orientation
      ### we only continue to extract useful information about this alignment if 1 was returned
      if ($valid_alignment_found_1 == 1){
	### Bowtie outputs which made it this far are in the correct orientation, so we can continue to analyse the alignment itself
	### need to extract the chromosome number from the bowtie output (which is either XY_cf (complete forward) or XY_cr (complete reverse)
	my ($id,$strand,$mapped_chromosome,$position,$bowtie_sequence,$mismatch_info) = (split (/\t/,$fhs[$index]->{last_line}))[0,1,2,3,4,7];
	chomp $mismatch_info;
	my ($chromosome,$bisulfite_genome_strand) = split (/_/,$mapped_chromosome);	
	$bisulfite_genome_strand =~ s/^c//;
	### Now extracting the number of mismatches to the converted genome
	my $number_of_mismatches;
	if ($mismatch_info eq ''){
	  $number_of_mismatches = 0;
	}
	elsif ($mismatch_info =~ /^\d/){
	  my @mismatches = split (/,/,$mismatch_info);
	  $number_of_mismatches = scalar @mismatches;
	}
	else{
	  die "Something weird is going on with the mismatch field\n";
	}
	### creating a composite location variable from $chromosome and $position and storing the alignment information in a temporary hash table
	my $alignment_location = join (":",$chromosome,$position);
	### If a sequence aligns to exactly the same location twice the sequence does either not contain any C or G, or all the Cs (or Gs on the reverse
	### strand) were methylated and therefore protected. It is not needed to overwrite the same positional entry with a second entry for the same
	### location (the genomic sequence extraction and methylation would not be affected by this, only the thing which would change is the index
	### number for the found alignment)
	unless (exists $mismatches{$number_of_mismatches}->{$alignment_location}){
	  $mismatches{$number_of_mismatches}->{$alignment_location}->{seq_id}=$id;
	  $mismatches{$number_of_mismatches}->{$alignment_location}->{bowtie_sequence}=$bowtie_sequence;
	  $mismatches{$number_of_mismatches}->{$alignment_location}->{index}=$index;
	  $mismatches{$number_of_mismatches}->{$alignment_location}->{chromosome}=$chromosome;
	  $mismatches{$number_of_mismatches}->{$alignment_location}->{position}=$position;
	}
	$number_of_mismatches = undef;
	##################################################################################################################################################
	### STEP II Now reading in the next line from the bowtie filehandle. The next alignment can either be a second alignment of the same sequence or a
	### a new sequence. In either case we will store the next line in @fhs ->{last_line}. In case the alignment is already the next entry, a 0 will
	### be returned as $valid_alignment_found and it will then be processed in the next round only.
	##################################################################################################################################################
	my $newline = $fhs[$index]->{fh}-> getline();
	if ($newline){
	  my ($seq_id) = split (/\t/,$newline);
	  $fhs[$index]->{last_seq_id} = $seq_id;
	  $fhs[$index]->{last_line} = $newline;
	}
	else {
	  # assigning undef to last_seq_id and last_line and jumping to the next index (end of bowtie output)
	  $fhs[$index]->{last_seq_id} = undef;
	  $fhs[$index]->{last_line} = undef;
	  next;
	}	
	my $valid_alignment_found_2 = decide_whether_single_end_alignment_is_valid($index,$identifier);
	### we only continue to extract useful information about this second alignment if 1 was returned
	if ($valid_alignment_found_2 == 1){
	  ### If the second Bowtie output made it this far it is in the correct orientation, so we can continue to analyse the alignment itself
	  ### need to extract the chromosome number from the bowtie output (which is either XY_cf (complete forward) or XY_cr (complete reverse)
	  my ($id,$strand,$mapped_chromosome,$position,$bowtie_sequence,$mismatch_info) = (split (/\t/,$fhs[$index]->{last_line}))[0,1,2,3,4,7];
	  chomp $mismatch_info;
	  my ($chromosome,$bisulfite_genome_strand) = split (/_/,$mapped_chromosome);	
	  $bisulfite_genome_strand =~ s/^c//;
	  ### Now extracting the number of mismatches to the converted genome
	  my $number_of_mismatches;
	  if ($mismatch_info eq ''){
	    $number_of_mismatches = 0;
	  }
	  elsif ($mismatch_info =~ /^\d/){
	    my @mismatches = split (/,/,$mismatch_info);
	    $number_of_mismatches = scalar @mismatches;
	  }
	  else{
	    die "Something weird is going on with the mismatch field\n";
	  }
	  ### creating a composite location variable from $chromosome and $position and storing the alignment information in a temporary hash table
	  ### extracting the chromosome number from the bowtie output (see above)
	  my $alignment_location = join (":",$chromosome,$position);
	  ### In the special case that two differently converted sequences align against differently converted genomes, but to the same position
	  ### with the same number of mismatches (or perfect matches), the chromosome, position and number of mismatches are the same. In this
	  ### case we are not writing the same entry out a second time.
	  unless (exists $mismatches{$number_of_mismatches}->{$alignment_location}){
	    $mismatches{$number_of_mismatches}->{$alignment_location}->{seq_id}=$id;
	    $mismatches{$number_of_mismatches}->{$alignment_location}->{bowtie_sequence}=$bowtie_sequence;
	    $mismatches{$number_of_mismatches}->{$alignment_location}->{index}=$index;
	    $mismatches{$number_of_mismatches}->{$alignment_location}->{chromosome}=$chromosome;
	    $mismatches{$number_of_mismatches}->{$alignment_location}->{position}=$position;
	  }
	  ####################################################################################################################################
	  #### STEP III Now reading in one more line which has to be the next alignment to be analysed. Adding it to @fhs ->{last_line}    ###
	  ####################################################################################################################################
	  $newline = $fhs[$index]->{fh}-> getline();
	  if ($newline){
	    my ($seq_id) = split (/\t/,$newline);
	    die "The same seq ID occurred more than twice in a row\n" if ($seq_id eq $identifier);
	    $fhs[$index]->{last_seq_id} = $seq_id;
	    $fhs[$index]->{last_line} = $newline;
	    next;
	  }	
	  else {
	    # assigning undef to last_seq_id and last_line and jumping to the next index (end of bowtie output)
	    $fhs[$index]->{last_seq_id} = undef;
	    $fhs[$index]->{last_line} = undef;
	    next;
	  }
	  ### still within the 2nd sequence in correct orientation found	
	}
	### still withing the 1st sequence in correct orientation found
      }
      ### still within the if (last_seq_id eq identifier) condition
    }
    ### still within foreach index loop
  }
  ### if there was no single alignment found for a certain sequence we will continue with the next sequence in the sequence file
  unless(%mismatches){
    $counting{no_single_alignment_found}++;
    return;
  }
  #######################################################################################################################################################
  #######################################################################################################################################################
  ### We are now looking if there is a unique best alignment for a certain sequence. This means we are sorting in ascending order and look at the     ###
  ### sequence with the lowest amount of mismatches. If there is only one single best position we are going to store the alignment information in the ###
  ### meth_call variables, if there are multiple hits with the same amount of (lowest) mismatches we are discarding the sequence altogether           ###
  #######################################################################################################################################################
  #######################################################################################################################################################
  ### Going to use the variable $sequence_fails as a 'memory' if a sequence could not be aligned uniquely (set to 1 then)
  my $sequence_fails = 0;
  ### Declaring an empty hash reference which will store all information we need for the methylation call
  my $methylation_call_params; # hash reference!
  ### sort without $a<=>$b sorts alphabetically, so 0,1,2,3... will be sorted correctly
  foreach my $mismatch_number (sort keys %mismatches){
    # foreach my $entry (keys (%{$mismatches{$mismatch_number}}) ){
    #   print join("\t",$mismatch_number,$entry,$mismatches{$mismatch_number}->{$entry}->{seq_id},$sequence,$mismatches{$mismatch_number}->{$entry}->{bowtie_sequence},$mismatches{$mismatch_number}->{$entry}->{chromosome},$mismatches{$mismatch_number}->{$entry}->{position},$mismatches{$mismatch_number}->{$entry}->{index}),"\n";
    # }
    #  print "\n";
    ### if there is only 1 entry in the hash with the lowest number of mismatches we accept it as the best alignment
    if (scalar keys %{$mismatches{$mismatch_number}} == 1){
      for my $unique_best_alignment (keys %{$mismatches{$mismatch_number}}){
	$methylation_call_params->{$identifier}->{bowtie_sequence} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{bowtie_sequence};
	$methylation_call_params->{$identifier}->{chromosome} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{chromosome};
	$methylation_call_params->{$identifier}->{position} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{position};
	$methylation_call_params->{$identifier}->{index} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{index};
      }
    }
    elsif (scalar keys %{$mismatches{$mismatch_number}} == 3){
      ### If there are 3 sequences with the same number of lowest mismatches we can discriminate 2 cases: (i) all 3 alignments are unique best hits and
      ### come from different alignments processes (== indices) or (ii) one sequence alignment (== index) will give a unique best alignment, whereas a
      ### second one will produce 2 (or potentially many) alignments for the same sequence but in a different conversion state or against a different genome
      ### version (or both). This becomes especially relevant for highly converted sequences in which all Cs have been converted to Ts in the bisulfite
      ### reaction. E.g.
      ### CAGTCACGCGCGCGCG will become
      ### TAGTTATGTGTGTGTG in the CT transformed version, which will ideally still give the correct alignment in the CT->CT alignment condition.
      ### If the same read will then become G->A transformed as well however, the resulting sequence will look differently and potentially behave
      ### differently in a GA->GA alignment and this depends on the methylation state of the original sequence!:
      ### G->A conversion:
      ### highly methylated: CAATCACACACACACA
      ### highly converted : TAATTATATATATATA <== this sequence has a reduced complexity (only 2 bases left and not 3), and it is more likely to produce
      ### an alignment with a low complexity genomic region than the one above. This would normally lead to the entire sequence being kicked out as the
      ### there will be 3 alignments with the same number of lowest mismatches!! This in turn means that highly methylated and thereby not converted
      ### sequences are more likely to pass the alignment step, thereby creating a bias for methylated reads compared to their non-methylated counterparts.
      ### We do not want any bias, whatsover. Therefore if we have 1 sequence producing a unique best alignment and the second and third conditions
      ### producing alignments only after performing an additional (theoretical) conversion we want to keep the best alignment with the lowest number of
      ### additional transliterations performed. Thus we want to have a look at the level of complexity of the sequences producing the alignment.
      ### In the above example the number of transliterations required to transform the actual sequence
      ### to the C->T version would be TAGTTATGTGTGTGTG -> TAGTTATGTGTGTGTG = 0; (assuming this gives the correct alignment)
      ### in the G->A case it would be TAGTTATGTGTGTGTG -> TAATTATATATATATA = 6; (assuming this gives multiple wrong alignments)
      ### if the sequence giving a unique best alignment required a lower number of transliterations than the second best sequence yielding alignments
      ### while requiring a much higher number of transliterations, we are going to accept the unique best alignment with the lowest number of performed
      ### transliterations. As a threshold which does scale we will start with the number of tranliterations of the lowest best match x 2 must still be
      ### smaller than the number of tranliterations of the second best sequence. Everything will be flagged with $sequence_fails = 1 and discarded.
      my @three_candidate_seqs;
      foreach my $composite_location (keys (%{$mismatches{$mismatch_number}}) ){
	my $transliterations_performed;
	if ($mismatches{$mismatch_number}->{$composite_location}->{index} == 0 or $mismatches{$mismatch_number}->{$composite_location}->{index} == 1){
	  $transliterations_performed = determine_number_of_transliterations_performed($sequence,'CT');
	}
	elsif ($mismatches{$mismatch_number}->{$composite_location}->{index} == 2 or $mismatches{$mismatch_number}->{$composite_location}->{index} == 3){
	  $transliterations_performed = determine_number_of_transliterations_performed($sequence,'GA');
	}
	else{
	  die "unexpected index number range $!\n";
	}
	push @three_candidate_seqs,{
				    index =>$mismatches{$mismatch_number}->{$composite_location}->{index},
				    bowtie_sequence => $mismatches{$mismatch_number}->{$composite_location}->{bowtie_sequence},
				    mismatch_number => $mismatch_number,
				    chromosome => $mismatches{$mismatch_number}->{$composite_location}->{chromosome},
				    position => $mismatches{$mismatch_number}->{$composite_location}->{position},
				    seq_id => $mismatches{$mismatch_number}->{$composite_location}->{seq_id},
				    transliterations_performed => $transliterations_performed,
				   };
      }
      ### sorting in ascending order for the lowest number of transliterations performed
      @three_candidate_seqs = sort {$a->{transliterations_performed} <=> $b->{transliterations_performed}} @three_candidate_seqs;
      my $first_array_element = $three_candidate_seqs[0]->{transliterations_performed};
      my $second_array_element = $three_candidate_seqs[1]->{transliterations_performed};
      my $third_array_element = $three_candidate_seqs[2]->{transliterations_performed};
      # print "$first_array_element\t$second_array_element\t$third_array_element\n";
      if (($first_array_element*2) < $second_array_element){
	$counting{low_complexity_alignments_overruled_count}++;
	### taking the index with the unique best hit and over ruling low complexity alignments with 2 hits
	$methylation_call_params->{$identifier}->{bowtie_sequence} = $three_candidate_seqs[0]->{bowtie_sequence};
	$methylation_call_params->{$identifier}->{chromosome} = $three_candidate_seqs[0]->{chromosome};
	$methylation_call_params->{$identifier}->{position} = $three_candidate_seqs[0]->{position};
	$methylation_call_params->{$identifier}->{index} = $three_candidate_seqs[0]->{index};
	# print "Overruled low complexity alignments! Using $first_array_element and disregarding $second_array_element and $third_array_element\n";
      }
      else{
	$sequence_fails = 1;
      }
    }
    else{
      $sequence_fails = 1;
    }
    ### after processing the alignment with the lowest number of mismatches we exit
    last;
  }
  ### skipping the sequence completely if there were multiple alignments with the same amount of lowest mismatches found at different positions
  if ($sequence_fails == 1){
    $counting{unsuitable_sequence_count}++;
    return; # => exits to next sequence
  }
  ### If the sequence has not been rejected so far it will have a unique best alignment
  $counting{unique_best_alignment_count}++;
  extract_corresponding_genomic_sequence_single_end($identifier,$methylation_call_params);
  ### check test to see if the genomic sequence we extracted has the same length as the observed sequence+1, and only then we perform the methylation call
  if (length($methylation_call_params->{$identifier}->{unmodified_genomic_sequence}) != length($sequence)+1){
    print "Chromosomal sequence could not be extracted for\t$methylation_call_params->{$identifier}->{seq_id}\t$methylation_call_params->{$identifier}->{chromosome}\t$methylation_call_params->{$identifier}->{position}\n";
  }
  ### otherwise we are set to perform the actual methylation call
  else{
    $methylation_call_params->{$identifier}->{methylation_call} = methylation_call($identifier,$sequence,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence},$methylation_call_params->{$identifier}->{read_conversion});
  }
  print_bisulfite_mapping_result_single_end($identifier,$sequence,$methylation_call_params);
}

sub determine_number_of_transliterations_performed{
  my ($sequence,$read_conversion) = @_;
  my $number_of_transliterations;
  if ($read_conversion eq 'CT'){
    $number_of_transliterations = $sequence =~ tr/C/T/;
  }
  elsif ($read_conversion eq 'GA'){
    $number_of_transliterations = $sequence =~ tr/G/A/;
  }
  else{
    die "Read conversion mode of the read was not specified $!\n";
  }
  return $number_of_transliterations;
}

sub decide_whether_single_end_alignment_is_valid{
  my ($index,$identifier) = @_;
  my ($id,$strand,$mapped_chromosome,$position,$bowtie_sequence,$mismatch_info) = (split (/\t/,$fhs[$index]->{last_line}))[0,1,2,3,4,7];
  ### ensuring that the entry is the correct sequence
  if (($id eq $fhs[$index]->{last_seq_id}) and ($id eq $identifier)){
    ### checking the orientation of the alignment. We need to discriminate between 8 different conditions, however only 4 of them are theoretically
    ### sensible alignments
    my $orientation = ensure_sensical_alignment_orientation_single_end ($index,$strand);
    ### If the orientation was correct can we move on
    if ($orientation == 1){
      return 1; ### 1st possibility for a sequence to pass
    }
    ### If the alignment was in the wrong orientation we need to read in a new line
    elsif($orientation == 0){
      my $newline = $fhs[$index]->{fh}->getline();
      if ($newline){
	### extract detailed information about the alignment again (from $newline this time)
	($id,$strand,$mapped_chromosome,$position,$bowtie_sequence,$mismatch_info) = (split (/\t/,$newline))[0,1,2,3,4,7];
	### ensuring that the next entry is still the correct sequence
	if ($id eq $identifier){
	  ### checking orientation again
	  $orientation = ensure_sensical_alignment_orientation_single_end ($index,$strand);
	  ### If the orientation was correct can we move on
	  if ($orientation == 1){
	    $fhs[$index]->{last_seq_id} = $id;
	    $fhs[$index]->{last_line} = $newline;
	    return 1; ### 2nd possibility for a sequence to pass
	  }
	  ### If the alignment was in the wrong orientation again we need to read in yet another new line and store it in @fhs
	  elsif ($orientation == 0){
	    $newline = $fhs[$index]->{fh}->getline();
	    if ($newline){
	      my ($seq_id) = split (/\t/,$newline);
	      ### check if the next line still has the same seq ID (must not happen), and if not overwrite the current seq-ID and bowtie output with
	      ### the same fields of the just read next entry
	      die "Same seq ID 3 or more times in a row!(should be 2 max) $!" if ($seq_id eq $identifier);
	      $fhs[$index]->{last_seq_id} = $seq_id;
	      $fhs[$index]->{last_line} = $newline;
	      return 0; # not processing anything this round as the alignment currently stored in last_line was in the wrong orientation
	    }
	    else{
	      # assigning undef to last_seq_id and last_line (end of bowtie output)
	      $fhs[$index]->{last_seq_id} = undef;
	      $fhs[$index]->{last_line} = undef;
	      return 0; # not processing anything as the alignment currently stored in last_line was in the wrong orientation
	    }
	  }
	  else{
	    die "The orientation of the alignment must be either correct or incorrect\n";
	  }
	}
	### the sequence we just read in is already the next sequence to be analysed -> store it in @fhs
	else{
	  $fhs[$index]->{last_seq_id} = $id;
	  $fhs[$index]->{last_line} = $newline;
	  return 0; # processing the new alignment result only in the next round
	}
      }
      else {
	# assigning undef to last_seq_id and last_line (end of bowtie output)
	$fhs[$index]->{last_seq_id} = undef;
	$fhs[$index]->{last_line} = undef;
	return 0; # not processing anything as the alignment currently stored in last_line was in the wrong orientation
      }
    }
    else{
      die "The orientation of the alignment must be either correct or incorrect\n";
    }
  }
  ### the sequence stored in @fhs as last_line is already the next sequence to be analysed -> analyse next round
  else{
    return 0;
  }
}

sub check_bowtie_results_paired_ends{
  my ($sequence_1,$sequence_2,$identifier) = @_;
  my %mismatches = ();
  ### reading from the bowtie output files to see if this sequence pair aligned to a bisulfite converted genome
  foreach my $index (0..$#fhs){
    ### skipping this index if the last alignment has been set to undefined already (i.e. end of bowtie output)
    next unless ($fhs[$index]->{last_line_1} and $fhs[$index]->{last_line_2} and $fhs[$index]->{last_seq_id});
    ### if the sequence pair we are currently looking at produced an alignment we are doing various things with it
    if ($fhs[$index]->{last_seq_id} eq $identifier) {
      ##################################################################################
      ### STEP I Processing the entry which is stored in last_line_1 and last_line_2 ###
      ##################################################################################
      my $valid_alignment_found = decide_whether_paired_end_alignment_is_valid($index,$identifier);
      ### sequences can fail at this point if there was only 1 alignment in the wrong orientation, or if there were 2 aligments both in the wrong
      ### orientation. We only continue to extract useful information about this alignment if 1 was returned
      if ($valid_alignment_found == 1){
	### Bowtie outputs which made it this far are in the correct orientation, so we can continue to analyse the alignment itself.
	### we store the useful information in %mismatches
	my ($id_1,$strand_1,$mapped_chromosome_1,$position_1,$bowtie_sequence_1,$mismatch_info_1) = (split (/\t/,$fhs[$index]->{last_line_1}))[0,1,2,3,4,7];
	my ($id_2,$strand_2,$mapped_chromosome_2,$position_2,$bowtie_sequence_2,$mismatch_info_2) = (split (/\t/,$fhs[$index]->{last_line_2}))[0,1,2,3,4,7];
	chomp $mismatch_info_1;
	chomp $mismatch_info_2;
	### need to extract the chromosome number from the bowtie output (which is either XY_cf (complete forward) or XY_cr (complete reverse)
	my ($chromosome_1,$bisulfite_genome_strand_1) = split (/_/,$mapped_chromosome_1);
	my ($chromosome_2,$bisulfite_genome_strand_2) = split (/_/,$mapped_chromosome_2);
	$bisulfite_genome_strand_1 =~ s/^c//;
	$bisulfite_genome_strand_2 =~ s/^c//;
	### Now extracting the number of mismatches to the converted genome
	my $number_of_mismatches_1;
	my $number_of_mismatches_2;
	if ($mismatch_info_1 eq ''){
	  $number_of_mismatches_1 = 0;
	}
	elsif ($mismatch_info_1 =~ /^\d/){
	  my @mismatches = split (/,/,$mismatch_info_1);
	  $number_of_mismatches_1 = scalar @mismatches;
	}
	else{
	  die "Something weird is going on with the mismatch field\n";
	}
	if ($mismatch_info_2 eq ''){
	  $number_of_mismatches_2 = 0;
	}
	elsif ($mismatch_info_2 =~ /^\d/){
	  my @mismatches = split (/,/,$mismatch_info_2);
	  $number_of_mismatches_2 = scalar @mismatches;
	}
	else{
	  die "Something weird is going on with the mismatch field\n";
	}
	### To decide whether a sequence pair has a unique best alignment we will look at the lowest sum of mismatches from both alignments
	my $sum_of_mismatches = $number_of_mismatches_1+$number_of_mismatches_2;
	### creating a composite location variable from $chromosome and $position and storing the alignment information in a temporary hash table
	die "Position 1 is higher than position 2" if ($position_1 > $position_2);
	die "Paired-end alignments need to be on the same chromosome\n" unless ($chromosome_1 eq $chromosome_2);
	my $alignment_location = join(":",$chromosome_1,$position_1,$position_2);
	### If a sequence aligns to exactly the same location twice the sequence does either not contain any C or G, or all the Cs (or Gs on the reverse
	### strand) were methylated and therefore protected. It is not needed to overwrite the same positional entry with a second entry for the same
	### location (the genomic sequence extraction and methylation would not be affected by this, only the thing which would change is the index
	### number for the found alignment)
	unless (exists $mismatches{$sum_of_mismatches}->{$alignment_location}){
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{seq_id}=$id_1; # either is fine
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{bowtie_sequence_1}=$bowtie_sequence_1;
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{bowtie_sequence_2}=$bowtie_sequence_2;
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{index}=$index;
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{chromosome}=$chromosome_1; # either is fine
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{start_seq_1}=$position_1;
	  $mismatches{$sum_of_mismatches}->{$alignment_location}->{start_seq_2}=$position_2;
	}
	###################################################################################################################################################
	### STEP II Now reading in the next 2 lines from the bowtie filehandle. If there are 2 next lines in the alignments filehandle it can either    ###
	### be a second alignment of the same sequence pair or a new sequence pair. In any case we will just add it to last_line_1 and last_line _2.    ###
	### If it is the alignment of the next sequence pair, 0 will be returned as $valid_alignment_found, so it will not be processed any further in  ###
	### this round                                                                                                                                  ###
	###################################################################################################################################################
	my $newline_1 = $fhs[$index]->{fh}-> getline();
	my $newline_2 = $fhs[$index]->{fh}-> getline();
	if ($newline_1 and $newline_2){
	  my ($seq_id_1) = split (/\t/,$newline_1);
	  my ($seq_id_2) = split (/\t/,$newline_2);
	  $seq_id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	  $seq_id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	  die "Seq IDs need to be identical\n" unless ($seq_id_1 eq $seq_id_2);
	  $fhs[$index]->{last_seq_id} = $seq_id_1; # either is fine
	  $fhs[$index]->{last_line_1} = $newline_1;
	  $fhs[$index]->{last_line_2} = $newline_2;
	}
	else {
	  # assigning undef to last_seq_id and both last_lines and jumping to the next index (end of bowtie output)
	  $fhs[$index]->{last_seq_id} = undef;
	  $fhs[$index]->{last_line_1} = undef;
	  $fhs[$index]->{last_line_2} = undef;
	  next; # jumping to the next index
	}
	### Now processing the entry we just stored in last_line_1 and last_line_2
	$valid_alignment_found = decide_whether_paired_end_alignment_is_valid($index,$identifier);
	### only processing the alignment further if 1 was returned. 0 will be returned either if the alignment is already the next sequence pair to
	### be analysed or if it was a second alignment of the current sequence pair but in the wrong orientation
	if ($valid_alignment_found == 1){
	  ### we store the useful information in %mismatches
	  ($id_1,$strand_1,$mapped_chromosome_1,$position_1,$bowtie_sequence_1,$mismatch_info_1) = (split (/\t/,$fhs[$index]->{last_line_1}))[0,1,2,3,4,7];
	  ($id_2,$strand_2,$mapped_chromosome_2,$position_2,$bowtie_sequence_2,$mismatch_info_2) = (split (/\t/,$fhs[$index]->{last_line_2}))[0,1,2,3,4,7];
	  chomp $mismatch_info_1;
	  chomp $mismatch_info_2;
	  ### need to extract the chromosome number from the bowtie output (which is either XY_cf (complete forward) or XY_cr (complete reverse)
	  ($chromosome_1,$bisulfite_genome_strand_1) = split (/_/,$mapped_chromosome_1);	
	  ($chromosome_2,$bisulfite_genome_strand_2) = split (/_/,$mapped_chromosome_2);
	  $bisulfite_genome_strand_1 =~ s/^c//;
	  $bisulfite_genome_strand_2 =~ s/^c//;
	  $number_of_mismatches_1='';
	  $number_of_mismatches_2='';
	  ### Now extracting the number of mismatches to the converted genome
	  if ($mismatch_info_1 eq ''){
	    $number_of_mismatches_1 = 0;
	  }
	  elsif ($mismatch_info_1 =~ /^\d/){
	    my @mismatches = split (/,/,$mismatch_info_1);
	    $number_of_mismatches_1 = scalar @mismatches;
	  }
	  else{
	    die "Something weird is going on with the mismatch field\n";
	  }
	  if ($mismatch_info_2 eq ''){
	    $number_of_mismatches_2 = 0;
	  }
	  elsif ($mismatch_info_2 =~ /^\d/){
	    my @mismatches = split (/,/,$mismatch_info_2);
	    $number_of_mismatches_2 = scalar @mismatches;
	  }
	  else{
	    die "Something weird is going on with the mismatch field\n";
	  }
	  ### To decide whether a sequence pair has a unique best alignment we will look at the lowest sum of mismatches from both alignments
	  $sum_of_mismatches = $number_of_mismatches_1+$number_of_mismatches_2;
	  ### creating a composite location variable from $chromosome and $position and storing the alignment information in a temporary hash table
	  die "position 1 is greater than position 2" if ($position_1 > $position_2);
	  die "Paired-end alignments need to be on the same chromosome\n" unless ($chromosome_1 eq $chromosome_2);
	  $alignment_location = join(":",$chromosome_1,$position_1,$position_2);
	  ### If a sequence aligns to exactly the same location twice the sequence does either not contain any C or G, or all the Cs (or Gs on the reverse
	  ### strand) were methylated and therefore protected. It is not needed to overwrite the same positional entry with a second entry for the same
	  ### location (the genomic sequence extraction and methylation would not be affected by this, only the thing which would change is the index
	  ### number for the found alignment)
	  unless (exists $mismatches{$sum_of_mismatches}->{$alignment_location}){
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{seq_id}=$id_1; # either is fine
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{bowtie_sequence_1}=$bowtie_sequence_1;
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{bowtie_sequence_2}=$bowtie_sequence_2;
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{index}=$index;
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{chromosome}=$chromosome_1; # either is fine
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{start_seq_1}=$position_1;
	    $mismatches{$sum_of_mismatches}->{$alignment_location}->{start_seq_2}=$position_2;
	  }
	  ###############################################################################################################################################
	  ### STEP III Now reading in two more lines. These have to be the next entry and we will just add assign them to last_line_1 and last_line_2 ###
	  ###############################################################################################################################################
	  $newline_1 = $fhs[$index]->{fh}-> getline();
	  $newline_2 = $fhs[$index]->{fh}-> getline();
	  if ($newline_1 and $newline_2){
	    my ($seq_id_1) = split (/\t/,$newline_1);
	    my ($seq_id_2) = split (/\t/,$newline_2);
	    $seq_id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	    $seq_id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	    die "Seq IDs need to be identical\n" unless ($seq_id_1 eq $seq_id_2);
	    $fhs[$index]->{last_seq_id} = $seq_id_1; # either is fine
	    $fhs[$index]->{last_line_1} = $newline_1;
	    $fhs[$index]->{last_line_2} = $newline_2;
	  }
	  else {
	    # assigning undef to last_seq_id and both last_lines and jumping to the next index (end of bowtie output)
	    $fhs[$index]->{last_seq_id} = undef;
	    $fhs[$index]->{last_line_1} = undef;
	    $fhs[$index]->{last_line_2} = undef;
	    next; # jumping to the next index
	  }
	  ### within the 2nd sequence pair alignment in correct orientation found
	}
	### within the 1st sequence pair alignment in correct orientation found
      }
      ### still within the (last_seq_id eq identifier) condition
    }
    ### still within foreach index loop
  }
  ### if there was no single alignment found for a certain sequence we will continue with the next sequence in the sequence file
  unless(%mismatches){
    $counting{no_single_alignment_found}++;
    return;
  }
  ### Going to use the variable $sequence_pair_fails as a 'memory' if a sequence could not be aligned uniquely (set to 1 then)
  my $sequence_pair_fails = 0;
  ### Declaring an empty hash reference which will store all information we need for the methylation call
  my $methylation_call_params; # hash reference!
  ### We are now looking if there is a unique best alignment for a certain sequence. This means we are sorting in ascending order and look at the
  ### sequence with the lowest amount of mismatches. If there is only one single best position we are going to store the alignment information in the
  ### meth_call variables, if there are multiple hits with the same amount of (lowest) mismatches we are discarding the sequence altogether
  foreach my $mismatch_number (sort keys %mismatches){
    #dev print "Number of mismatches: $mismatch_number\t$identifier\t$sequence_1\t$sequence_2\n";
    foreach my $entry (keys (%{$mismatches{$mismatch_number}}) ){
      #dev print "$mismatch_number\t$entry\t$mismatches{$mismatch_number}->{$entry}->{index}\n";
      # print join("\t",$mismatch_number,$mismatches{$mismatch_number}->{$entry}->{seq_id},$sequence,$mismatches{$mismatch_number}->{$entry}->{bowtie_sequence},$mismatches{$mismatch_number}->{$entry}->{chromosome},$mismatches{$mismatch_number}->{$entry}->{position},$mismatches{$mismatch_number}->{$entry}->{index}),"\n";
    }
    if (scalar keys %{$mismatches{$mismatch_number}} == 1){
      #  print "Unique best alignment for sequence pair $sequence_1\t$sequence_1\n";
      for my $unique_best_alignment (keys %{$mismatches{$mismatch_number}}){
	$methylation_call_params->{$identifier}->{seq_id} = $identifier;
 	$methylation_call_params->{$identifier}->{bowtie_sequence_1} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{bowtie_sequence_1};
	$methylation_call_params->{$identifier}->{bowtie_sequence_2} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{bowtie_sequence_2};
       	$methylation_call_params->{$identifier}->{chromosome} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{chromosome};
      	$methylation_call_params->{$identifier}->{start_seq_1} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{start_seq_1};
	$methylation_call_params->{$identifier}->{start_seq_2} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{start_seq_2};
	$methylation_call_params->{$identifier}->{alignment_end} = ($mismatches{$mismatch_number}->{$unique_best_alignment}->{start_seq_2}+length($mismatches{$mismatch_number}->{$unique_best_alignment}->{bowtie_sequence_2}));
	$methylation_call_params->{$identifier}->{index} = $mismatches{$mismatch_number}->{$unique_best_alignment}->{index};
      }
    }
    else{
      $sequence_pair_fails = 1;
    }
    ### after processing the alignment with the lowest number of mismatches we exit
    last;
  }
  ### skipping the sequence completely if there were multiple alignments with the same amount of lowest mismatches found at different positions
  if ($sequence_pair_fails == 1){
    $counting{unsuitable_sequence_count}++;
    return;
  }
  ### If the sequence has not been rejected so far it does have a unique best alignment
  $counting{unique_best_alignment_count}++;
  extract_corresponding_genomic_sequence_paired_ends($identifier,$methylation_call_params);
  ### check test to see if the genomic sequences we extracted has the same length as the observed sequences, and only then we perform the methylation call
  if (length($methylation_call_params->{$identifier}->{unmodified_genomic_sequence_1}) != length($sequence_1)+1){
    print "Chromosomal sequence could not be extracted for\t$methylation_call_params->{$identifier}->{seq_id}\t$methylation_call_params->{$identifier}->{chromosome}\t$methylation_call_params->{$identifier}->{start_seq_1}\n";
  }
  elsif (length($methylation_call_params->{$identifier}->{unmodified_genomic_sequence_2}) != length($sequence_2)+1){
    print "Chromosomal sequence could not be extracted for\t$methylation_call_params->{$identifier}->{seq_id}\t$methylation_call_params->{$identifier}->{chromosome}\t$methylation_call_params->{$identifier}->{start_seq_2}\n";
  }
  ### otherwise we are set to perform the actual methylation call
  else{
    $methylation_call_params->{$identifier}->{methylation_call_1} = methylation_call($identifier,$sequence_1,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence_1},$methylation_call_params->{$identifier}->{read_conversion_1});
    $methylation_call_params->{$identifier}->{methylation_call_2} = methylation_call($identifier,$sequence_2,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence_2},$methylation_call_params->{$identifier}->{read_conversion_2});
  }
  print_bisulfite_mapping_results_paired_ends($identifier,$sequence_1,$sequence_2,$methylation_call_params);
}

sub decide_whether_paired_end_alignment_is_valid{
  my ($index,$identifier) = @_;
  my ($id_1,$strand_1,$mapped_chromosome_1,$position_1,$bowtie_sequence_1,$mismatch_info_1) = (split (/\t/,$fhs[$index]->{last_line_1}))[0,1,2,3,4,7];
  my ($id_2,$strand_2,$mapped_chromosome_2,$position_2,$bowtie_sequence_2,$mismatch_info_2) = (split (/\t/,$fhs[$index]->{last_line_2}))[0,1,2,3,4,7];
  chomp $mismatch_info_1;
  chomp $mismatch_info_2;
  my $seq_id_1 = $id_1;
  my $seq_id_2 = $id_2;
  $seq_id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
  $seq_id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
  ### ensuring that the current entry is the correct sequence
  if ($seq_id_1 eq $seq_id_2 and $seq_id_1 eq $identifier){
    ### checking the orientation of the alignment. We need to discriminate between 8 different conditions, however only 4 of them are theoretically
    ### sensible alignments
    my $orientation = ensure_sensical_alignment_orientation_paired_ends ($index,$id_1,$strand_1,$id_2,$strand_2);
    ### If the orientation was correct can we move on
    if ($orientation == 1){
      return 1; ### 1st possibility for A SEQUENCE-PAIR TO PASS
    }
    ### If the alignment was in the wrong orientation we need to read in two new lines
    elsif($orientation == 0){
      my $newline_1 = $fhs[$index]->{fh}->getline();
      my $newline_2 = $fhs[$index]->{fh}->getline();
      if ($newline_1 and $newline_2){
	### extract detailed information about the alignment again (from $newline_1 and $newline_2 this time)
	($id_1,$strand_1) = (split (/\t/,$newline_1))[0,1];
	($id_2,$strand_2) = (split (/\t/,$newline_2))[0,1];
	$seq_id_1 = $id_1;
	$seq_id_2 = $id_2;
	$seq_id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	$seq_id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	### ensuring that the next entry is still the correct sequence
	if ($seq_id_1 eq $seq_id_2 and $seq_id_1 eq $identifier){
	  ### checking orientation again
	  $orientation = ensure_sensical_alignment_orientation_paired_ends ($index,$id_1,$strand_1,$id_2,$strand_2);
	  ### If the orientation was correct can we move on
	  if ($orientation == 1){
	    ### Writing the current sequence to last_line_1 and last_line_2
	    $fhs[$index]->{last_seq_id} = $seq_id_1; # either is fine
	    $fhs[$index]->{last_line_1} = $newline_1;
	    $fhs[$index]->{last_line_2} = $newline_2;
	    return 1; ### 2nd possibility for a SEQUENCE-PAIR TO PASS
	  }
	  ### If the alignment was in the wrong orientation again we need to read in yet another 2 new lines and store them in @fhs (this must be
	  ### the next entry)
	  elsif ($orientation == 0){
	    $newline_1 = $fhs[$index]->{fh}->getline();
	    $newline_2 = $fhs[$index]->{fh}->getline();
	    if ($newline_1 and $newline_2){
	      ($seq_id_1) = split (/\t/,$newline_1);
	      ($seq_id_2) = split (/\t/,$newline_2);
	      $seq_id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	      $seq_id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
	      die "Seq IDs need to be identical\n" unless ($seq_id_1 eq $seq_id_2);
	      ### check if the next 2 lines still have the same seq ID (must not happen), and if not overwrite the current seq-ID and bowtie output with
	      ### the same fields of the just read next entry
	      die "Same seq ID 3 or more times in a row!(should be 2 max)" if ($seq_id_1 eq $identifier);
	      $fhs[$index]->{last_seq_id} = $seq_id_1; # either is fine
	      $fhs[$index]->{last_line_1} = $newline_1;
	      $fhs[$index]->{last_line_2} = $newline_2;
	      return 0; # not processing anything this round as the alignment currently stored in last_line_1 and _2 was in the wrong orientation
	    }
	    else {
	      ### assigning undef to last_seq_id and last_line (end of bowtie output)
	      $fhs[$index]->{last_seq_id} = undef;
	      $fhs[$index]->{last_line_1} = undef;
	      $fhs[$index]->{last_line_2} = undef;
	      return 0; # not processing anything as the alignment currently stored in last_line_1 and _2 was in the wrong orientation
	    }
	  }
	  else{
	    die "The orientation of the alignment must be either correct or incorrect\n";
	  }
	}
	### the sequence pair we just read in is already the next sequence pair to be analysed -> store it in @fhs
	else{
	  $fhs[$index]->{last_seq_id} = $seq_id_1; # either is fine
	  $fhs[$index]->{last_line_1} = $newline_1;
	  $fhs[$index]->{last_line_2} = $newline_2;
	  return 0; # processing the new alignment result only in the next round
	}
      }
      else {
	# assigning undef to last_seq_id and both last_lines (end of bowtie output)
	$fhs[$index]->{last_seq_id} = undef;
	$fhs[$index]->{last_line_1} = undef;
	$fhs[$index]->{last_line_2} = undef;
	return 0; # not processing anything as the alignment currently stored in last_line_1 and _2 was in the wrong orientation
      }
    }
    else{
      die "The orientation of the alignment must be either correct or incorrect\n";
    }
  }
  ### the sequence pair stored in @fhs as last_line_1 and last_line_2 is already the next sequence pair to be analysed -> analyse next round
  else{
    return 0;
  }
}

sub extract_corresponding_genomic_sequence_paired_ends {
   my ($sequence_identifier,$methylation_call_params) = @_;
   ### A bisulfite sequence pair for 1 location in the genome can theoretically be on any of the 4 possible converted strands. We are also giving the
   ### sequence a 'memory' of the conversion we are expecting which we will need later for the methylation call
   my $alignment_read_1;
   my $alignment_read_2;
   my $read_conversion_info_1;
   my $read_conversion_info_2;

   ### Now extracting the same sequence from the mouse genomic sequence, +1 extra base at the end so that we can also make a CpG methylation call
   ### if the C happens to be at the last position of the actually observed sequence
   my $non_bisulfite_sequence_1;
   my $non_bisulfite_sequence_2;

   ### all alignments reported by bowtie have the + alignment first and the - alignment as the second one irrespective of whether read 1 or read 2 was
   ### the + alignment. We however always read in sequences read 1 then read 2, so if read 2 is the + alignment we need to swap the extracted genomic
   ### sequences around!
   ### results from CT converted read 1 plus GA converted read 2 vs. CT converted genome (+/- orientation alignments are reported only)
   if ($methylation_call_params->{$sequence_identifier}->{index} == 0){
     ### [Index 0, sequence originated from (converted) forward strand]
     $counting{CT_GA_CT_count}++;
     $alignment_read_1 = '+';
     $alignment_read_2 = '-';
     $read_conversion_info_1 = 'CT';
     $read_conversion_info_2 = 'GA';
     ### SEQUENCE 1 (this is always the forward hit, in this case it is read 1)
     ### for hits on the forward strand we need to capture 1 extra base at the 3' end
     $non_bisulfite_sequence_1 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{start_seq_1},length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_1})+1);
     ### SEQUENCE 2 (this will always be on the reverse strand, in this case it is read 2)
     ### As the second conversion is GA we need to capture 1 base 3', so that it is a 5' base after reverse complementation
     $non_bisulfite_sequence_2 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_2}),length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_2})+1);
     ### the reverse strand sequence needs to be reverse complemented
     $non_bisulfite_sequence_2 = reverse_complement($non_bisulfite_sequence_2);
   }

   ### results from GA converted read 1 plus CT converted read 2 vs. GA converted genome (+/- orientation alignments are reported only)
   elsif ($methylation_call_params->{$sequence_identifier}->{index} == 1){
     ### [Index 1, sequence originated from (converted) reverse strand]
     $counting{GA_CT_GA_count}++;
     $alignment_read_1 = '+';
     $alignment_read_2 = '-';
     $read_conversion_info_1 = 'GA';
     $read_conversion_info_2 = 'CT';
     ### SEQUENCE 1 (this is always the forward hit, in this case it is read 1)
     ### as we need to make the methylation call for the base 5' of the first base (GA conversion!) we need to capture 1 extra base at the 5' end
     $non_bisulfite_sequence_1 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{start_seq_1}-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_1})+1);
     ### SEQUENCE 2 (this will always be on the reverse strand, in this case it is read 2)
     ### As we are doing a CT comparison for the reverse strand we are taking 1 base extra at the 5' end, so it is a 5' base after reverse complementation
     $non_bisulfite_sequence_2 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_2})-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_2})+1);
     ### the reverse strand sequence needs to be reverse complemented
     $non_bisulfite_sequence_2 = reverse_complement($non_bisulfite_sequence_2);
   }

   ### results from GA converted read 1 plus CT converted read 2 vs. CT converted genome (-/+ orientation alignments are reported only)
   elsif ($methylation_call_params->{$sequence_identifier}->{index} == 2){
     ### [Index 2, sequence originated from the complementary to (converted) forward strand]
     $counting{GA_CT_CT_count}++;
     $alignment_read_1 = '-';
     $alignment_read_2 = '+';
     $read_conversion_info_1 = 'GA';
     $read_conversion_info_2 = 'CT';
     ### Here we switch the sequence information round!!  non_bisulfite_sequence_1 will later correspond to the read 1!!!!
     ### SEQUENCE 1 (this is always the forward hit, in this case it is READ 2), read 1 is in - orientation on the reverse strand
     ### As read 1 is GA converted we need to capture 1 extra 3' base which will be 1 extra 5' base after reverse complementation
     $non_bisulfite_sequence_1 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_2}),length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_2})+1);
     ### the reverse strand sequence needs to be reverse complemented
     $non_bisulfite_sequence_1 = reverse_complement($non_bisulfite_sequence_1);
     ### SEQUENCE 2 (this will always be on the reverse strand, in this case it is READ 1)
     ### non_bisulfite_sequence_2 will later correspond to the read 2!!!!
     ### Read 2 is CT converted so we need to capture 1 extra 3' base
     $non_bisulfite_sequence_2 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_1}),length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_1})+1);
   }

   ### results from CT converted read 1 plus GA converted read 2 vs. GA converted genome (-/+ orientation alignments are reported only)
   elsif ($methylation_call_params->{$sequence_identifier}->{index} == 3){
     ### [Index 3, sequence originated from the complementary to (converted) reverse strand]
     $counting{CT_GA_GA_count}++;
     $alignment_read_1 = '-';
     $alignment_read_2 = '+';
     $read_conversion_info_1 = 'CT';
     $read_conversion_info_2 = 'GA';
     ### Here we switch the sequence information round!!  non_bisulfite_sequence_1 will later correspond to the read 1!!!!
     ### SEQUENCE 1 (this is always the forward hit, in this case it is READ 2), read 1 is in - orientation on the reverse strand
     ### As read 1 is CT converted we need to capture 1 extra 5' base which will be 1 extra 3' base after reverse complementation
     $non_bisulfite_sequence_1 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_2})-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_2})+1);
     ### the reverse strand sequence needs to be reverse complemented
     $non_bisulfite_sequence_1 = reverse_complement($non_bisulfite_sequence_1);
     ### SEQUENCE 2 (this will always be on the reverse strand, in this case it is READ 1)
     ### non_bisulfite_sequence_2 will later correspond to the read 2!!!!
     ### Read 2 is GA converted so we need to capture 1 extra 5' base
     $non_bisulfite_sequence_2 = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},($methylation_call_params->{$sequence_identifier}->{start_seq_1})-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence_1})+1);
   }
   else{
     die "Too many bowtie result filehandles\n";
   }
   ### the alignment_strand information is needed to determine which strand of the genomic sequence we are comparing the read against,
   ### the read_conversion information is needed to know whether we are looking for C->T or G->A substitutions
   $methylation_call_params->{$sequence_identifier}->{alignment_read_1} = $alignment_read_1;
   $methylation_call_params->{$sequence_identifier}->{alignment_read_2} = $alignment_read_2;
   $methylation_call_params->{$sequence_identifier}->{read_conversion_1} = $read_conversion_info_1;
   $methylation_call_params->{$sequence_identifier}->{read_conversion_2} = $read_conversion_info_2;
   $methylation_call_params->{$sequence_identifier}->{unmodified_genomic_sequence_1} = $non_bisulfite_sequence_1;
   $methylation_call_params->{$sequence_identifier}->{unmodified_genomic_sequence_2} = $non_bisulfite_sequence_2;
}

sub print_bisulfite_mapping_result_single_end{
  my ($identifier,$sequence,$methylation_call_params)= @_;
  ### writing every single mapped read and its methylation call to one comprehensive output file
  my $comprehensive_bowtie_output = join("\t",$identifier,$methylation_call_params->{$identifier}->{alignment_strand},$methylation_call_params->{$identifier}->{chromosome},$methylation_call_params->{$identifier}->{position},$sequence,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence},$methylation_call_params->{$identifier}->{methylation_call},$methylation_call_params->{$identifier}->{index},$fhs[$methylation_call_params->{$identifier}->{index}]->{name},$fhs[$methylation_call_params->{$identifier}->{index}]->{strand_identity});
  print OUT "$comprehensive_bowtie_output\n";
}

sub print_bisulfite_mapping_results_paired_ends{
  my ($identifier,$sequence_1,$sequence_2,$methylation_call_params)= @_;
  ### writing every single mapped read and its methylation call to one comprehensive output file
  my $comprehensive_BiSeq_mapping_output_paired_ends = join("\t",$identifier,$methylation_call_params->{$identifier}->{alignment_read_1},$methylation_call_params->{$identifier}->{chromosome},$methylation_call_params->{$identifier}->{start_seq_1},$methylation_call_params->{$identifier}->{alignment_end},$sequence_1,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence_1},$methylation_call_params->{$identifier}->{methylation_call_1},$sequence_2,$methylation_call_params->{$identifier}->{unmodified_genomic_sequence_2},$methylation_call_params->{$identifier}->{methylation_call_2},$methylation_call_params->{$identifier}->{index},$fhs[$methylation_call_params->{$identifier}->{index}]->{name},$fhs[$methylation_call_params->{$identifier}->{index}]->{strand_identity});
  print OUT "$comprehensive_BiSeq_mapping_output_paired_ends\n";
}

sub extract_corresponding_genomic_sequence_single_end {
  my ($sequence_identifier,$methylation_call_params) = @_;
  ### A bisulfite sequence for 1 location in the genome can theoretically be any of the 4 possible converted strands. We are also giving the
  ### sequence a 'memory' of the conversion we are expecting which we will need later for the methylation call

  ### the alignment_strand information is needed to determine which strand of the genomic sequence we are comparing the read against,
  ### the read_conversion information is needed to know whether we are looking for C->T or G->A substitutions
  my $alignment_strand;
  my $read_conversion_info;

  ### Also extracting the corresponding sequence from the mouse genomic sequence, +1 extra base at the end so that we can also make a CpG methylation call
  ### if the C happens to be at the last position of the actually observed sequence
  my $non_bisulfite_sequence;
  ### depending on the conversion we want to make need to capture 1 extra base at the 3' end

  ### results from CT converted read vs. CT converted genome (+ orientation alignments are reported only)
  if ($methylation_call_params->{$sequence_identifier}->{index} == 0){
    ### [Index 0, sequence originated from (converted) forward strand]
    $counting{CT_CT_count}++;
    $alignment_strand = '+';
    $read_conversion_info = 'CT';
    ### + 1 extra base at the 3' end
    $non_bisulfite_sequence = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{position},length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence})+1);
  }
  ### results from CT converted reads vs. GA converted genome (- orientation alignments are reported only)
  elsif ($methylation_call_params->{$sequence_identifier}->{index} == 1){
    ### [Index 1, sequence originated from (converted) reverse strand]
    $counting{CT_GA_count}++;
    $alignment_strand = '-';
    $read_conversion_info = 'CT';
    ### Extracting 1 extra 5' base on forward strand which will become 1 extra 3' base after reverse complementation
    $non_bisulfite_sequence = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{position}-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence})+1);
    ## reverse complement!
    $non_bisulfite_sequence = reverse_complement($non_bisulfite_sequence);
  }
  ### results from GA converted reads vs. CT converted genome (- orientation alignments are reported only)
  elsif ($methylation_call_params->{$sequence_identifier}->{index} == 2){
    ### [Index 2, sequence originated from complementary to (converted) forward strand]
    $counting{GA_CT_count}++;
    $alignment_strand = '-';
    $read_conversion_info = 'GA';
    ### +1 extra base on the forward strand 3', which will become 1 extra 5' base after reverse complementing it
    $non_bisulfite_sequence = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{position},length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence})+1);
    ## reverse complement!
    $non_bisulfite_sequence = reverse_complement($non_bisulfite_sequence);
  }
  ### results from GA converted reads vs. GA converted genome (+ orientation alignments are reported only)
  elsif ($methylation_call_params->{$sequence_identifier}->{index} == 3){
    ### [Index 3, sequence originated from complementary to (converted) reverse strand]
    $counting{GA_GA_count}++;
    $alignment_strand = '+';
    $read_conversion_info = 'GA';
    ### +1 extra base at the 5' end as we are nominally checking the converted reverse strand
    $non_bisulfite_sequence = substr ($chromosomes{$methylation_call_params->{$sequence_identifier}->{chromosome}},$methylation_call_params->{$sequence_identifier}->{position}-1,length($methylation_call_params->{$sequence_identifier}->{bowtie_sequence})+1);
  }
  else{
    die "Too many bowtie result filehandles\n";
  }
  $methylation_call_params->{$sequence_identifier}->{alignment_strand} = $alignment_strand;
  $methylation_call_params->{$sequence_identifier}->{read_conversion} = $read_conversion_info;
  $methylation_call_params->{$sequence_identifier}->{unmodified_genomic_sequence} = $non_bisulfite_sequence;
}

sub methylation_call{
  my ($identifier,$sequence_actually_observed,$genomic_sequence,$read_conversion) = @_;
  ### splitting both the actually observed sequence and the genomic sequence up into single bases so we can compare them one by one
  my @seq = split(//,$sequence_actually_observed);
  my @genomic = split(//,$genomic_sequence);
  #  print join ("\n",$identifier,$sequence_actually_observed,$genomic_sequence,$read_conversion),"\n";
  ### Creating a match-string with different characters for non-cytosine bases (disregarding mismatches here), methyl-Cs or non-methyl Cs in either
  ### CpG or any other context
  ############################################################
  ### . for bases not involving cytosines                  ###
  ### C for methylated C (was protected)                   ###
  ### c for not methylated C (was converted)               ###
  ### Z for methylated C in CpG context (was protected)    ###
  ### z for not methylated C in CpG context (was converted)###
  ############################################################
  my @match =();
  warn "length of \@seq: ",scalar @seq,"\tlength of \@genomic: ",scalar @genomic,"\n" unless (scalar @seq eq (scalar@genomic-1));
  my $methyl_C_count = 0;
  my $methyl_CpG_count = 0;
  my $unmethylated_C_count = 0;
  my $unmethylated_CpG_count = 0;

  if ($read_conversion eq 'CT'){
    for my $index (0..$#seq) {
      if ($seq[$index] eq $genomic[$index]) {
	### The residue can only be a C if it was not converted to T, i.e. protected my methylation
	if ($genomic[$index] eq 'C') {
	  ### If the residue is a C we want to know if it was in CpG context or in any other context
	  my $downstream_base = $genomic[$index+1];
	  if ($downstream_base eq 'G'){
	    ++$methyl_CpG_count;
	    push @match,'Z'; # protected C, methylated, in CpG context
	  }
	  elsif ($downstream_base =~ /[CATN]/){
	    ++$methyl_C_count;
	    push @match,'C'; # protected C, methylated, not CpG context
	  }
	  else{
	    die "Genomic sequence contained unexpected base: $downstream_base\n";
	  }
	}
	else{
	  push @match, '.';
	}
      }
      elsif ($seq[$index] ne $genomic[$index]) {
	### for the methylation call we are only interested in mismatches involving Cytosines (in the genomic sequence) which were converted to T
	### in the actuallly observed sequence
	if ($genomic[$index] eq 'C' and $seq[$index] eq 'T') {
	  ### If the residue was converted to T we want to know if it was in CpG context or in any other context
	  my $downstream_base = $genomic[$index+1];
	  if ($downstream_base eq 'G'){
	    ++$unmethylated_CpG_count;
	    push @match,'z'; # converted C, not methylated, in CpG context
	  }
	  elsif ($downstream_base =~ /[CATN]/){
	    ++$unmethylated_C_count;
	    push @match,'c'; # converted C, not methylated, not CpG context
	  }
	  else{
	    die "Genomic sequence contained unexpected base: $downstream_base\n";
	  }
	}
	### all other mismatches are not of interest for a methylation call
	else {
	  push @match,'.';
	}
      }
      else{
	die "There can be only 2 possibilities\n";
      }
    }
  }
  elsif ($read_conversion eq 'GA'){
    for my $index (0..$#seq) {
      if ($seq[$index] eq $genomic[$index+1]) {
	### The residue can only be a G if the C on the other strand was not converted to T, i.e. protected my methylation
	if ($genomic[$index+1] eq 'G') {
	  ### If the residue is a G we want to know if the C on the other strand was in CpG context or in any other context, therefore we need
	  ### to look if the base upstream is a C
	  my $upstream_base = $genomic[$index];
	  if ($upstream_base eq 'C'){
	    ++$methyl_CpG_count;
	    push @match,'Z'; # protected C on opposing strand, methylated, in CpG context
	  }
	  elsif ($upstream_base =~ /[GATN]/){
	    ++$methyl_C_count;
	    push @match,'C'; # protected C on opposing strand, methylated, not CpG context
	  }
	  else{
	    die "Genomic sequence contained unexpected base: $upstream_base\n";
	  }
	}
	else{
	  push @match, '.';
	}
      }
      elsif ($seq[$index] ne $genomic[$index+1]) {
	### for the methylation call we are only interested in mismatches involving Cytosines (in the genomic sequence) which were converted to T
	### on the opposing strand, so G to A conversions in the actuallly observed sequence
	if ($genomic[$index+1] eq 'G' and $seq[$index] eq 'A') {
	  ### If the C residue on the opposing strand was converted to T then we will see an A in the currently observed sequence. We want to know if
	  ### the C on the opposing strand was it was in CpG context or in any other context, therefore we need to look one base upstream!
	  my $upstream_base = $genomic[$index];
	  if ($upstream_base eq 'C'){
	    ++$unmethylated_CpG_count;
	    push @match,'z'; # converted C on opposing strand, not methylated, in CpG context
	  }
	  elsif ($upstream_base =~ /[GATN]/){
	    ++$unmethylated_C_count;
	    push @match,'c'; # converted C on opposing strand, not methylated, not CpG context
	  }
	  else{
	    die "Genomic sequence contained unexpected base: $upstream_base\n";
	  }
	}
	### all other mismatches are not of interest for a methylation call
	else {
	  push @match,'.';
	}
      }
      else{
	die "There can be only 2 possibilities\n";
      }
    }
  }
  else{
    die "Strand conversion info is required to perform a methylation call\n";
  }
  my $methylation_call = join ("",@match);
  $counting{total_meC_count} += $methyl_C_count;
  $counting{total_meCpG_count} += $methyl_CpG_count;
  $counting{total_unmethylated_C_count} += $unmethylated_C_count;
  $counting{total_unmethylated_CpG_count} += $unmethylated_CpG_count;
  # print "\n$sequence_actually_observed\n$genomic_sequence\n",@match,"\n$read_conversion\n\n";
  return $methylation_call;
}

sub read_genome_into_memory{
  ### working directoy
  my $cwd = shift;
  ### reading in and storing the specified genome in the %chromosomes hash
  chdir ($genome_folder) or die "Can't move to $genome_folder: $!";
  print "Now reading in and storing sequence information of the genome specified in: $genome_folder\n\n";
  while (my $chromosome_filename = <*.fa>){
    my $chromosome_number = chromosome_number($chromosome_filename);
    my $sequence = read_chromosomal_sequence($chromosome_filename);
    $chromosomes{$chromosome_number}= $sequence;
    print "chr $chromosome_number\t";
  }
  print "\n";
  chdir $cwd or die "Failed to move to directory $cwd\n";
}

sub read_chromosomal_sequence{
  my $filename = shift @_;
  my $sequence;
  # warn "Reading sequence data from $filename\n";
  open (CHROMOSOME,$filename)or die "Can't open $filename: $!";
  $_ = <CHROMOSOME>;
  while (<CHROMOSOME>){
    chomp;
    $sequence .= uc$_;
  }
  close CHROMOSOME or die "Failed to close filehandle\n";
  return $sequence;
}

sub chromosome_number{
  my $filename = shift @_;
  if ($filename =~ /\.([^\.]+)\.fa$/){
    return $1;
  }
  else{
    die "Unable to extract the chromosome number: $filename!";
  }
}

sub reverse_complement{
  my $sequence = shift;
  $sequence =~ tr/CATG/GTAC/;
  $sequence = reverse($sequence);
  return $sequence;
}

sub biTransformFastAFiles {
  my $filename = shift;
  open (IN,$filename) or die "Couldn't read from file $filename: $!\n";
  my $C_to_T_infile = my $G_to_A_infile = $filename;
  $C_to_T_infile =~ s/\.fa$/_C_to_T.fa/;
  $G_to_A_infile =~ s/\.fa$/_G_to_A.fa/;
  print "Writing a C -> T converted version of the input file $filename to $C_to_T_infile\n";
  print "Writing a G -> A converted version of the input file $filename to $G_to_A_infile\n";
  open (CTOT,'>',$C_to_T_infile) or die "Couldn't write to file $!\n";
  open (GTOA,'>',$G_to_A_infile) or die "Couldn't write to file $!\n";
  my $count =0;
  while (1){
    my $header = <IN>;
    my $sequence= <IN>;
    $sequence = uc$sequence; # make input file case insensitive
    last unless ($header and $sequence);
    ++$count;
    ## small check if the sequence seems to be in FastA format
    die "Input file doesn't seem to be in FastA format at sequence $count: $!\n" unless ($header =~ /^>.*/);
    my $sequence_C_to_T = my $sequence_G_to_A = $sequence;
    $sequence_C_to_T =~ tr/C/T/;
    $sequence_G_to_A =~ tr/G/A/;
    print CTOT "$header$sequence_C_to_T";
    print GTOA "$header$sequence_G_to_A";
  }
  print "\nCreated C -> T as well as G -> A converted versions of the FastA file $filename ($count sequences in total)\n\n";
  return ($C_to_T_infile,$G_to_A_infile);
}

sub biTransformFastQFiles {
  my $filename = shift;
  open (IN,$filename) or die "Couldn't read from file $filename: $!\n";
  my $C_to_T_infile = my $G_to_A_infile = $filename;
  $C_to_T_infile =~ s/$/_C_to_T.fastq/;
  $G_to_A_infile =~ s/$/_G_to_A.fastq/;
  print "Writing a C -> T converted version of the input file $filename to $C_to_T_infile\n";
  print "Writing a G -> A converted version of the input file $filename to $G_to_A_infile\n";
  open (CTOT,'>',$C_to_T_infile) or die "Couldn't write to file $!\n";
  open (GTOA,'>',$G_to_A_infile) or die "Couldn't write to file $!\n";
  my $count =0;
  while (1){
    my $identifier = <IN>;
    my $sequence = <IN>;
    my $identifier2 = <IN>;
    my $quality_score = <IN>;
    last unless ($identifier and $sequence and $identifier2 and $quality_score);
    ++$count;
    $sequence= uc$sequence; # make input file case insensitive
    ## small check if the sequence file appears to be a FastQ file
    if ($identifier !~ /^\@/ or $identifier2 !~ /^\+/){
      die "Input file doesn't seem to be in FastQ format at sequence $count: $!\n";
    }
    my $sequence_C_to_T = my $sequence_G_to_A = $sequence;
    $sequence_C_to_T =~ tr/C/T/;
    $sequence_G_to_A =~ tr/G/A/;
    print CTOT join ('',$identifier,$sequence_C_to_T,$identifier2,$quality_score);
    print GTOA join ('',$identifier,$sequence_G_to_A,$identifier2,$quality_score);
  }
  print "\nCreated C -> T as well as G -> A converted versions of the FastA file $filename ($count sequences in total)\n\n";
  return ($C_to_T_infile,$G_to_A_infile);
}

sub ensure_sensical_alignment_orientation_single_end{
  my $index = shift; # index number if the sequence produced an alignment
  my $strand = shift;
  ###  setting $orientation to 1 if it is in the correct orientation, and leave it 0 if it is the nonsensical wrong one
  my $orientation = 0;
  ##############################################################################################################
  ## FORWARD converted read against FORWARD converted genome (read: C->T.....C->T..      genome:C->T.......C->T)
  ## here we only want reads in the forward (+) orientation
  if ($fhs[$index]->{name} eq 'CTreadCTgenome') {
    ### if the alignment is (+) we count it, and return 1 for a correct orientation
    if ($strand eq '+') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the orientation equals (-) the alignment is nonsensical
    elsif ($strand eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
  }
  ###############################################################################################################
  ## FORWARD converted read against reverse converted genome (read: C->T.....C->T..      genome: G->A.......G->A)
  ## here we only want reads in the forward (-) orientation
  elsif ($fhs[$index]->{name} eq 'CTreadGAgenome') {
    ### if the alignment is (-) we count it and return 1 for a correct orientation
    if ($strand eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the orientation equals (+) the alignment is nonsensical
    elsif ($strand eq '+') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
  }
  ###############################################################################################################
  ## Reverse converted read against FORWARD converted genome (read: G->A.....G->A..      genome: C->T.......C->T)
  ## here we only want reads in the forward (-) orientation
  elsif ($fhs[$index]->{name} eq 'GAreadCTgenome') {
    ### if the alignment is (-) we count it and return 1 for a correct orientation
    if ($strand eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the orientation equals (+) the alignment is nonsensical
    elsif ($strand eq '+') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
  }
  ###############################################################################################################
  ## Reverse converted read against reverse converted genome (read: G->A.....G->A..      genome: G->A.......G->A)
  ## here we only want reads in the forward (+) orientation
  elsif ($fhs[$index]->{name} eq 'GAreadGAgenome') {
    ### if the alignment is (+) we count it and return 1 for a correct orientation
    if ($strand eq '+') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the orientation equals (-) the alignment is nonsensical
    elsif ($strand eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
  } else{
    die "One of the above conditions must be true\n";
  }
}

sub ensure_sensical_alignment_orientation_paired_ends{
  my ($index,$id_1,$strand_1,$id_2,$strand_2) = @_; # index number if the sequence produced an alignment
  ###  setting $orientation to 1 if it is in the correct orientation, and leave it 0 if it is the nonsensical wrong one
  my $orientation = 0;
  ##############################################################################################################
  ## [Index 0, sequence originated from (converted) forward strand]
  ## CT converted read 1
  ## GA converted read 2
  ## CT converted genome
  ## here we only want read 1 in (+) orientation and read 2 in (-) orientation
  if ($fhs[$index]->{name} eq 'CTread1GAread2CTgenome') {
    ### if the paired-end alignment is read1 (+) and read2 (-) we count it, and return 1 for a correct orientation
    if ($id_1 =~ /1$/ and $strand_1 eq '+' and $id_2 =~ /2$/ and $strand_2 eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the read 2 is in (+) orientation and read 1 in (-) the alignment is nonsensical
    elsif ($id_1 =~ /2$/ and $strand_1 eq '+' and $id_2 =~ /1$/ and $strand_2 eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
    else{
      die "id1: $id_1\tid2: $id_2\tThis should be impossible\n";
    }
  }
  ###############################################################################################################
  ## [Index 1, sequence originated from (converted) reverse strand]
  ## GA converted read 1
  ## CT converted read 2
  ## GA converted genome
  ## here we only want read 1 in (+) orientation and read 2 in (-) orientation
  elsif ($fhs[$index]->{name} eq 'GAread1CTread2GAgenome') {
    ### if the paired-end alignment is read1 (+) and read2 (-) we count it, and return 1 for a correct orientation
    if ($id_1 =~ /1$/ and $strand_1 eq '+' and $id_2 =~ /2$/ and $strand_2 eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the read 2 is in (+) orientation and read 1 in (-) the alignment is nonsensical
    elsif ($id_1 =~ /2$/ and $strand_1 eq '+' and $id_2 =~ /1$/ and $strand_2 eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
    else{
      die "id1: $id_1\tid2: $id_2\tThis should be impossible\n";
    }
  }
  ###############################################################################################################
  ## [Index 2, sequence originated from complementary to (converted) forward strand]
  ## GA converted read 1
  ## CT converted read 2
  ## CT converted genome
  ## here we only want read 1 in (-) orientation and read 2 in (+) orientation
  elsif ($fhs[$index]->{name} eq 'GAread1CTread2CTgenome') {
    ### if the paired-end alignment is read1 (-) and read2 (+) we count it, and return 1 for a correct orientation
    if ($id_1 =~ /2$/ and $strand_1 eq '+' and $id_2 =~ /1$/ and $strand_2 eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the read 2 is in (+) orientation and read 1 in (-) the alignment is nonsensical
    elsif ($id_1 =~ /1$/ and $strand_1 eq '+' and $id_2 =~ /2$/ and $strand_2 eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
    else{
      die "id1: $id_1\tid2: $id_2\tThis should be impossible\n";
    }
  }
  ###############################################################################################################
  ## [Index 3, sequence originated from complementary to (converted) reverse strand]
  ## CT converted read 1
  ## GA converted read 2
  ## GA converted genome
  ## here we only want read 1 in (+) orientation and read 2 in (-) orientation
  elsif ($fhs[$index]->{name} eq 'CTread1GAread2GAgenome') {
    ### if the paired-end alignment is read1 (-) and read2 (+) we count it, and return 1 for a correct orientation
    if ($id_1 =~ /2$/ and $strand_1 eq '+' and $id_2 =~ /1$/ and $strand_2 eq '-') {
      $fhs[$index]->{seen}++;
      $orientation = 1;
      return $orientation;
    }
    ### if the read 2 is in (+) orientation and read 1 in (-) the alignment is nonsensical
    elsif ($id_1 =~ /1$/ and $strand_1 eq '+' and $id_2 =~ /2$/ and $strand_2 eq '-') {
      $fhs[$index]->{wrong_strand}++;
      return $orientation;
    }
    else{
      die "id1: $id_1\tid2: $id_2\tThis should be impossible\n";
    }
  }
  else{
    die "One of the above conditions must be true\n";
  }
}

sub paired_end_align_fragments_to_bisulfite_genome_fastA {
  my ($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;
  print "Input files are $C_to_T_infile_1 and $G_to_A_infile_1 and $C_to_T_infile_2 and $G_to_A_infile_2 (FastA)\n";

  ## Now starting 4 instances of Bowtie feeding in the converted sequence files and reading in the first line of the bowtie output, and storing it in
  ## data structure above
  warn "Now running 4 individual instances of Bowtie against the bisulfite genome of $genome_folder with the specified options: $bowtie_options\n\n";
  foreach my $fh (@fhs) {
    warn "Now starting a Bowtie paired-end alignment for $fh->{name} (reading in sequences from $fh->{inputfile_1} and $fh->{inputfile_2})\n";
    open ($fh->{fh},"$path_to_bowtie $bowtie_options $fh->{bisulfiteIndex} -1 $fh->{inputfile_1} -2 $fh->{inputfile_2} |") or die "Can't open pipe to bowtie: $!";

    my $line_1 = $fh->{fh}->getline();
    my $line_2 = $fh->{fh}->getline();

    # if Bowtie produces an alignment we store the first line of the output
    if ($line_1 and $line_2) {
      my $id_1 = (split(/\t/),$line_1)[0]; # this is the first element of the first bowtie output line (= the sequence identifier)
      my $id_2 = (split(/\t/),$line_2)[0]; # this is the first element of the second bowtie output line
      $id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
      $id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
      if ($id_1 eq $id_2){
	$fh->{last_seq_id} = $id_1; # either will do
      }
      else {
	die "Sequence IDs do not match!\n"
      }
      $fh->{last_line_1} = $line_1; # this does contain the read 1 or read 2 tag
      $fh->{last_line_2} = $line_2; # this does contain the read 1 or read 2 tag
      warn "Found first alignment:\n$fh->{last_line_1}$fh->{last_line_2}";
    }
    # otherwise we just initialise last_seq_id and last_lines as undefined
    else {
      print "Found no alignment, assigning undef to last_seq_id and last_lines\n";
      $fh->{last_seq_id_1} = undef;
      $fh->{last_seq_id_2} = undef;
      $fh->{last_line_1} = undef;
      $fh->{last_line_2} = undef;
    }
  }
}

sub paired_end_align_fragments_to_bisulfite_genome_fastQ {
  my ($C_to_T_infile_1,$G_to_A_infile_1,$C_to_T_infile_2,$G_to_A_infile_2) = @_;
  print "Input files are $C_to_T_infile_1 and $G_to_A_infile_1 and $C_to_T_infile_2 and $G_to_A_infile_2 (FastQ)\n";

  ## Now starting 4 instances of Bowtie feeding in the converted sequence files and reading in the first line of the bowtie output, and storing it in
  ## data structure above
  warn "Now running 4 individual instances of Bowtie against the bisulfite genome of $genome_folder with the specified options: $bowtie_options\n\n";
  foreach my $fh (@fhs) {
    warn "Now starting a Bowtie paired-end alignment for $fh->{name} (reading in sequences from $fh->{inputfile_1} and $fh->{inputfile_2})\n";
    open ($fh->{fh},"$path_to_bowtie $bowtie_options $fh->{bisulfiteIndex} -1 $fh->{inputfile_1} -2 $fh->{inputfile_2} |") or die "Can't open pipe to bowtie: $!";

    my $line_1 = $fh->{fh}->getline();
    my $line_2 = $fh->{fh}->getline();

    # if Bowtie produces an alignment we store the first line of the output
    if ($line_1 and $line_2) {
      my $id_1 = (split(/\t/,$line_1))[0]; # this is the first element of the first bowtie output line (= the sequence identifier)
      my $id_2 = (split(/\t/,$line_2))[0]; # this is the first element of the second bowtie output line
      $id_1 =~ s/\/[12]//; # removing the read 1 or read 2 tag
      $id_2 =~ s/\/[12]//; # removing the read 1 or read 2 tag
      if ($id_1 eq $id_2){
	$fh->{last_seq_id} = $id_1; # either will do
      }
      else {
	die "Sequence IDs do not match!\n"
      }
      $fh->{last_line_1} = $line_1; # this does contain the read 1 or read 2 tag
      $fh->{last_line_2} = $line_2; # this does contain the read 1 or read 2 tag
      warn "Found first alignment:\n$fh->{last_line_1}$fh->{last_line_2}";
    }
    # otherwise we just initialise last_seq_id and last_lines as undefined
    else {
      print "Found no alignment, assigning undef to last_seq_id and last_lines\n";
      $fh->{last_seq_id_1} = undef;
      $fh->{last_seq_id_2} = undef;
      $fh->{last_line_1} = undef;
      $fh->{last_line_2} = undef;
    }
  }
}

sub single_end_align_fragments_to_bisulfite_genome_fastA {
  my $C_to_T_infile = shift;
  my $G_to_A_infile = shift;
  print "Input files are $C_to_T_infile and $G_to_A_infile (FastA)\n";

  ## Now starting 4 instances of Bowtie feeding in the converted sequence files and reading in the first line of the bowtie output, and storing it in
  ## data structure above
  warn "Now running 4 individual instances of Bowtie against the bisulfite genome of $genome_folder with the specified options: $bowtie_options\n\n";
  foreach my $fh (@fhs) {
    warn "Now starting the Bowtie aligner for $fh->{name} (reading in sequences from $fh->{inputfile})\n";
    open ($fh->{fh},"$path_to_bowtie $bowtie_options $fh->{bisulfiteIndex} $fh->{inputfile} |") or die "Can't open pipe to bowtie: $!";

    # if Bowtie produces an alignment we store the first line of the output
    my $_ = $fh->{fh}->getline();
    if ($_) {
      my $id = (split(/\t/))[0]; # this is the first element of the bowtie output (= the sequence identifier)
      $fh->{last_seq_id} = $id;
      $fh->{last_line} = $_;
      warn "Found first alignment:\t$fh->{last_line}\n";
    }
    # otherwise we just initialise last_seq_id and last_line as undefinded
    else {
      print "Found no alignment, assigning undef to last_seq_id and last_line\n";
      $fh->{last_seq_id} = undef;
      $fh->{last_line} = undef;
    }
  }
}

sub single_end_align_fragments_to_bisulfite_genome_fastQ {
  my $C_to_T_infile = shift;
  my $G_to_A_infile = shift;
  print "Input files are $C_to_T_infile and $G_to_A_infile (FastQ)\n";

  ## Now starting 4 instances of Bowtie feeding in the converted sequence files and reading in the first line of the bowtie output, and storing it in
  ## the data structure above
  warn "Now running 4 individual instances of Bowtie against the bisulfite genome of $genome_folder with the specified options: $bowtie_options\n\n";
  foreach my $fh (@fhs) {
    warn "Now starting the Bowtie aligner for $fh->{name} (reading in sequences from $fh->{inputfile})\n";
    open ($fh->{fh},"$path_to_bowtie $bowtie_options $fh->{bisulfiteIndex} $fh->{inputfile} |") or die "Can't open pipe to bowtie: $!";

    # if Bowtie produces an alignment we store the first line of the output
    my $_ = $fh->{fh}->getline();
    if ($_) {
      my $id = (split(/\t/))[0]; # this is the first element of the bowtie output (= the sequence identifier)
      $fh->{last_seq_id} = $id;
      $fh->{last_line} = $_;
      warn "Found first alignment:\t$fh->{last_line}\n";
    }
    # otherwise we just initialise last_seq_id and last_line as undefined
    else {
      print "Found no alignment, assigning undef to last_seq_id and last_line\n";
      $fh->{last_seq_id} = undef;
      $fh->{last_line} = undef;
    }
  }
}

sub reset_counters_and_fhs{
  %counting=(
	     total_meC_count => 0,
	     total_meCpG_count => 0,
	     total_unmethylated_C_count => 0,
	     total_unmethylated_CpG_count => 0,
	     sequences_count => 0,
	     no_single_alignment_found => 0,
	     unsuitable_sequence_count => 0,
	     unique_best_alignment_count => 0,
	     low_complexity_alignments_overruled_count => 0,
	     CT_CT_count => 0, #(CT read/CT genome)
	     CT_GA_count => 0, #(CT read/GA genome)
	     GA_CT_count => 0, #(GA read/CT genome)
	     GA_GA_count => 0, #(GA read/GA genome)
	     CT_GA_CT_count => 0, #(CT read1/GA read2/CT genome)
	     GA_CT_GA_count => 0, #(GA read1/CT read2/GA genome)
	     GA_CT_CT_count => 0, #(GA read1/CT read2/CT genome)
	     CT_GA_GA_count => 0, #(CT read1/GA read2/GA genome)
	    );
  @fhs=(
	{ name => 'CTreadCTgenome',
	  strand_identity => 'con ori forward',
	  bisulfiteIndex => $CT_index_basename,
	  seen => 0,
	  wrong_strand => 0,
	},
	{ name => 'CTreadGAgenome',
	  strand_identity => 'con ori reverse',
	  bisulfiteIndex => $GA_index_basename,
	  seen => 0,
	  wrong_strand => 0,
	},
	{ name => 'GAreadCTgenome',
	  strand_identity => 'compl ori con forward',
	  bisulfiteIndex => $CT_index_basename,
	  seen => 0,
	  wrong_strand => 0,
	},
	{ name => 'GAreadGAgenome',
	  strand_identity => 'compl ori con reverse',
	  bisulfiteIndex => $GA_index_basename,
	  seen => 0,
	  wrong_strand => 0,
	},
       );
}


sub process_command_line{
  my @bowtie_options;
  my $help;
  my $mates1;
  my $mates2;
  my $path_to_bowtie;
  my $fastq;
  my $fasta;
  my $skip;
  my $qupto;
  my $trim5;
  my $trim3;
  my $phred64;
  my $phred33;
  my $solexa;
  my $mismatches;
  my $seed_length;
  my $best;
  my $sequence_format;
  my $command_line = GetOptions ('help|man' => \$help,
				 '1=s' => \$mates1,
				 '2=s' => \$mates2,
				 'path_to_bowtie=s' => \$path_to_bowtie,
				 'f|fasta' => \$fasta,
				 'q|fastq' => \$fastq,
				 's|skip=i' => \$skip,
				 'u|qupto=i' => \$qupto,
				 '5|trim5=i' => \$trim5,
				 '3|trim3=i' => \$trim3,
				 'phred33-quals' => \$phred33,
				 'phred64-quals|solexa1' => \$phred64,
				 'solexa-quals' => \$solexa,
				 'n|seedmms=i' => \$mismatches,
				 'l|seedlen=i' => \$seed_length,
				 'best' => \$best,
				);
  ### EXIT ON ERROR if there were errors with any of the supplied options
  unless ($command_line){
    die "Please respecify command line options\n";
  }
  ### HELPFILE
  if ($help){
    print_helpfile();
    exit;
  }


  ##################################
  ### PROCESSING OPTIONS

  ### PATH TO BOWTIE
  ### if a special path to Bowtie was specified we will use that one, otherwise it is assumed that Bowtie is in the path
  if ($path_to_bowtie){
    unless ($path_to_bowtie =~ /\/$/){
      $path_to_bowtie =~ s/$/\//;
    }
    if (-d $path_to_bowtie){
      $path_to_bowtie = "${path_to_bowtie}bowtie";
    }
    else{
      die "The path to bowtie provided ($path_to_bowtie) is invalid (not a directory)!\n";
    }
  }
  else{
    $path_to_bowtie = 'bowtie';
  }
  print "Path to Bowtie specified as: $path_to_bowtie\n";

  ####################################
  ### PROCESSING ARGUMENTS

  ### GENOME FOLDER
  my $genome_folder = shift @ARGV; # mandatory
  unless ($genome_folder){
    warn "Genome folder was not specified!\n";
    print_helpfile();
    exit;
  }

  ### checking that the genome folder, all subfolders and the required bowtie index files exist
  unless ($genome_folder =~/\/$/){
    $genome_folder =~ s/$/\//;
  }
  my $CT_dir = "${genome_folder}Bisulfite_Genome/CT_conversion/";
  my $GA_dir = "${genome_folder}Bisulfite_Genome/GA_conversion/";
  if (chdir $genome_folder){
    print "Reference genome folder provided is $genome_folder\n";
  }
  else{
    die "Failed to move to $genome_folder: $!\nUSAGE: Bismark.pl [options] <genome_folder> {-1 <mates1> -2 <mates2> | <singles>} [<hits>]    (--help for more details)\n";
  }
  ### checking the integrity of $CT_dir
  chdir $CT_dir or die "Failed to move to directory $CT_dir: $!\n";
  my @CT_bowtie_index = ('BS_CT.1.ebwt','BS_CT.2.ebwt','BS_CT.3.ebwt','BS_CT.4.ebwt','BS_CT.rev.1.ebwt','BS_CT.rev.2.ebwt');
  foreach my $file(@CT_bowtie_index){
    unless (-f $file){
      die "The bowtie index of the C->T converted genome seems to be faulty ($file). Please run Bismark_Genome_Preparation before running Bismark.pl.\n";
    }
  }
  my $CT_index_basename = "${CT_dir}BS_CT";
  ### checking the integrity of $GA_dir
  chdir $GA_dir or die "Failed to move to directory $GA_dir: $!\n";
  my @GA_bowtie_index = ('BS_GA.1.ebwt','BS_GA.2.ebwt','BS_GA.3.ebwt','BS_GA.4.ebwt','BS_GA.rev.1.ebwt','BS_GA.rev.2.ebwt');
  foreach my $file(@GA_bowtie_index){
    unless (-f $file){
      die "The bowtie index of the C->T converted genome seems to be faulty ($file). Please run Bismark_Genome_Preparation before running Bismark.pl.\n";
    }
  }
  my $GA_index_basename = "${GA_dir}BS_GA";


  ### INPUT OPTIONS

  ### SEQUENCE FILE FORMAT
  ### exits if both fastA and FastQ were specified
  if ($fasta and $fastq){
    die "Only one sequence filetype can be specified (fastA or fastQ)\n";
  }

  ### unless fastA is specified explicitely, fastQ sequence format is expected by default
  if ($fasta){
    print "FastA format specified\n";
    $sequence_format = 'FASTA';
    push @bowtie_options, '-f';
  }
  elsif ($fastq){
    print "FastQ format specified\n";
    $sequence_format = 'FASTQ';
    push @bowtie_options, '-q';
  }
  else{
    $fastq=1;
    print "FastQ format assumed (by default)\n";
    $sequence_format = 'FASTQ';
    push @bowtie_options, '-q';
  }

  ### SKIP
  if ($skip){
    push @bowtie_options,"-s $skip";
  }

  ### UPTO
  if ($qupto){
    push @bowtie_options,"--qupto $qupto";
  }

  ### TRIM 5'-END
  if ($trim5){
    push @bowtie_options,"--trim5 $trim5";
  }

  ### TRIM 3'-END
  if ($trim3){
    push @bowtie_options,"--trim3 $trim3";
  }

  ### QUALITY VALUES
  if (($phred33 and $phred64) or ($phred33 and $solexa) or ($phred64 and $solexa)){
    die "You can only specify one type of quality value at a time! (--phred33-quals or --phred64-quals or --solexa-quals)";
  }
  if ($phred33){
    # Phred quality values work only when -q is specified
    unless ($fastq){
      die "Phred quality values works only when -q (FASTQ) is specified\n";
    }
    push @bowtie_options,"--phred33-quals";
  }
  if ($phred64){
    # Phred quality values work only when -q is specified
    unless ($fastq){
      die "Phred quality values work only when -q (FASTQ) is specified\n";
    }
    push @bowtie_options,"--phred64-quals";
  }
  if ($solexa){
    # Solexa to Phred value conversion works only when -q is specified
    unless ($fastq){
      die "Conversion from Solexa to Phred quality values works only when -q (FASTQ) is specified\n";
    }
    push @bowtie_options,"--solexa-quals";
  }

  ### ALIGNMENT OPTIONS

  ### MISMATCHES
  if ($mismatches){
    push @bowtie_options,"-n $mismatches";
  }
  ### SEED LENGTH
  if ($seed_length){
    push @bowtie_options,"-l $seed_length";
  }

  ### REPORTING OPTIONS
  # Because of the way Bismark works we will always use the reporting option -k 2 (report up to 2 valid alignments)
  push @bowtie_options,'-k 2';

  ### --BEST
  if ($best){
    push @bowtie_options,'--best';
  }

  ### PAIRED-END MAPPING
  if ($mates1){
    my @mates1 = (split (',',$mates1));
    die "Paired-end mapping requires the format: -1 <mates1> -2 <mates2>, please respecify!\n" unless ($mates2);
    my @mates2 = (split(',',$mates2));
    unless (scalar @mates1 == scalar @mates2){
      die "Paired-end mapping requires the same amounnt of mate1 and mate2 files, please respecify! (format: -1 <mates1> -2 <mates2>)\n";
    }
    while (1){
      my $mate1 = shift @mates1;
      my $mate2 = shift @mates2;
      last unless ($mate1 and $mate2);
      push @filenames,"$mate1,$mate2";
    }
  }
  elsif ($mates2){
    die "Paired-end mapping requires the format: -1 <mates1> -2 <mates2>, please respecify!\n";
  }

  ### SINGLE-END MAPPING
  # Single-end mapping will be performed if no mate pairs for paired-end mapping have been specified
  my $singles;
  unless ($mates1 and $mates2){
    $singles = shift @ARGV;
    @filenames = (split(',',$singles));
  }

  ### SUMMARY OF ALL BOWTIE OPTIONS
  my $bowtie_options = join (' ',@bowtie_options);
  return ($genome_folder,$CT_index_basename,$GA_index_basename,$path_to_bowtie,$sequence_format,$bowtie_options);
}

sub print_helpfile{
  print << 'HOW_TO';


DESCRIPTION


The following is a brief description of command line options and arguments to control the Bismark
bisulfite mapping and methylation call script. Bismark takes in FastA or FastQ files and aligns the
reads to a specified bisulfite genome. We are going to take sequence reads and transform the sequence
into a bisulfite converted forward strand (C->T conversion) or into a bisulfite treated reverse strand
(G->A conversion of the forward strand). We then align each of these reads to bisulfite treated forward
strand index of the mouse genome (C -> T converted) and a bisulfite treated reverse strand index of the
genome (G -> A conversion on the forward strand, by doing this alignments will produce the same positions).
These 4 instances of bowtie will be run in parallel. We are then going to read in the sequence file again
line by line to pull out the original sequence from the mouse genome and determine if there were any
protected C's present or not. We are then going to print out the methylation calls into a final result file.

For Single-end analysis, the final BiSeq output of this script will be a single file in bowtie format (tab delimited) with all sequences which do
have a unique best alignment to any of the 4 possible strands of a bisulfite PCR product. It will be in the following format:
(1) seq name (2) {+ or -} (3) chromosome (4) position (5) observed sequence (6) genomic sequence (7) methylation call string



USAGE: Bismark.pl [options] <genome_folder> {-1 <mates1> -2 <mates2> | <singles>} [<hits>]


ARGUMENTS:

<genome_folder>          The full path to the folder containing the unmodified reference genome
                         as well as the subfolders created by the Bismark_Genome_Preparation
                         script (/Bisulfite_Genome/CT_conversion/ and /Bisulfite_Genome/GA_conversion/). 
                         Bismark expects one or more fastA files in this folder (file extension: .fa).

-1 <mates1>              Comma-separated list of files containing the #1 mates (filename usually includes
                         "_1"), e.g. flyA_1.fq,flyB_1.fq). Sequences specified with this option must
                         correspond file-for-file and read-for-read with those specified in <mates2>.
                         Reads may be a mix of different lengths.

-2 <mates2>              Comma-separated list of files containing the #2 mates (filename usually includes
                         "_2"), e.g. flyA_1.fq,flyB_1.fq). Sequences specified with this option must
                         correspond file-for-file and read-for-read with those specified in <mates1>.
                         Reads may be a mix of different lengths.

<singles>                A comma-separated list of files containing the reads to be aligned (e.g. lane1.fq,
                         lane2.fq,lane3.fq). Reads may be a mix of different lengths.


OPTIONS:


Input:

-q/--fastq               The query input files (specified as <mate1>,<mate2> or <singles> are FASTQ
                         files (usually having extension .fg or .fastq). This is the default. See also
                         --solexa-quals and --integer-quals.

-f/--fasta               The query input files (specified as <mate1>,<mate2> or <singles> are FASTA
                         files (usually havin extension .fa, .mfa, .fna or similar). All quality values
                         are assumed to be 40 on the Phred scale.

-s/--skip <int>          Skip (i.e. do not align) the first <int> reads or read pairs from the input.

-u/--qupto <int>         Only aligns the first <int> reads or read pairs from the input. Default: no limit.

-5/--trim5 <int>         Trim <int> bases from the high-quality (left) end of each read before alignment.
                         Default: 0.

-3/--trim3 <int>         Trim <int> bases from the low-quality (right) end of each read before alignment.
                         Default: 0.

--phred33-quals          FASTQ qualities are ASCII chars equal to the Phred quality plus 33. Default: on.

--phred64-quals          FASTQ qualities are ASCII chars equal to the Phred quality plus 64. Default: off.

--solexa-quals           Convert FASTQ qualities from solexa-scaled (which can be negative) to phred-scaled
                         (which can't). The formula for conversion is: 
                         phred-qual = 10 * log(1 + 10 ** (solexa-qual/10.0)) / log(10). Used with -q. This
                         is usually the right option for use with (unconverted) reads emitted by the GA
                         Pipeline versions prior to 1.3. Default: off.

--solexa1.3-quals        Same as --phred64-quals. This is usually the right option for use with (unconverted)
                         reads emitted by GA Pipeline version 1.3 or later. Default: off.

--path_to_bowtie         The full path </../../> to the Bowtie installation on your system. If not specified
                         it will be assumed that Bowtie is in the path.


Alignment:

-n/--seedmms <int>       The maximum number of mismatches permitted in the "seed", which is the first 20 
                         base pairs of the read by default (see -l/--seedlen). This may be 0, 1, 2 or 3).

-l/--seedlen             The "seed length"; i.e., the number of bases of the high quality end of the read to 
                         which the -n ceiling applies. The default is 28.


Reporting:

-k <2>                   Due to the way Bismark works Bowtie will report up to 2 valid alignments. This option
                         will be used by default.

--best                   Make Bowtie guarantee that reported singleton alingments are "best" in terms of stratum
                         (i.e. number of mismatches, or mismatches in the seed in the case if -n mode) and in 
                         terms of the quality; e.g. a 1-mismatch alignment where the mismatch position has Phred
                         quality 40 is preferred over a 2-mismatch alignment where the mismatched positions both
                         have Phred quality 10. When --best is not specified, Bowtie may report alignments that
                         are sub-optimal in terms of stratum and/or quality (though an effort is made to report
                         the best alignment). --best mode also removes all strand bias. Note that --best does not
                         affect which alignments are considered "valid" by Bowtie, only which valid alignments
                         are reported by Bowtie. Bowtie is about 1-2.5 times slower when --best is specified.


Other:

-h/--help                Displays this help file.


This script was last edited on 18 May 2010.

HOW_TO
}
