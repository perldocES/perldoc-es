#!/usr/bin/env perl

# Copyright 2011-2016 by Enrique Nell
#
# Requires Pod::Simple::HTML

use 5.012;
use warnings;
use File::Copy;
use File::Basename;
use Readonly;
use Pod::Tidy qw( tidy_files );
use Text::WordDiff;
use Pod::Checker;
use Getopt::Long;
use Text::Unidecode;
use Unicode::Collate::Locale;
#use utf8;

$|++;

my (@names, $nohtml, $diff, $notrev);

my $result = GetOptions(
                        "pod=s"   => \@names,
                        "nohtml"  => \$nohtml,
                        "diff"    => \$diff,
                        "notrev"  => \$notrev,
                       );


die "Usage: perl postprocess.pl --pod <pod_name1> <pod_name2> ... [--nohtml] [--diff][--notrev]\n" 
    unless $names[0];


# Hard-coded paths relative to /perldoc-es/tools
# OmegaT project
Readonly my $SOURCE_PATH   => "../../omegat_work_prj/source";
Readonly my $TARGET_PATH   => "../../omegat_work_prj/target";
Readonly my $MEM_PATH      => "../../omegat_work_prj/omegat/project_save.tmx";   
# Clean OmegaT project (only reviewed segments)
Readonly my $CLEAN_PATH    => "../../omegat_clean_prj/source";
Readonly my $CLEANM_PATH   => "../../omegat_clean_prj/omegat/project_save.tmx";
# git repository
Readonly my $TRANSPOD_PATH => "../pod/translated";
Readonly my $REVPOD_PATH   => "../pod/reviewed";
Readonly my $DIFF_PATH     => "../pod/diff";
Readonly my $DISTR_PATH    => "../POD2-ES/lib/POD2/ES";
Readonly my $WORK_PATH     => "../memory/work/perlspanish-omegat.zipf.tmx";

# Diff file boilerplate
Readonly my $DIFF_HEADER   => <<"END_HEADER";
<html>
<head>
<META HTTP-EQUIV='Content-Type' CONTENT='text/html; charset=UTF-8'>
<style>
.file .fileheader { color: #888; }
.file .hunk ins   { color: #060; font-weight: bold; }
.file .hunk del   { color: #b22; font-weight: bold; }
</style>
</head>
<title>Word-oriented POD comparison</title>
<body>
END_HEADER

# File Not Reviewed Warning
Readonly my $NOT_REVIEWED => <<'END_WARNING';
=begin HTML

<p style="color:red"><strong>ADVERTENCIA: ESTE DOCUMENTO NO EST� REVISADO.<br> 
Se incluye en la distribuci�n como borrador �til e informativo, pero su lectura puede 
resultar dura para l@s perler@s con mayor sensibilidad ling��stica.</strong></p>

=end HTML
END_WARNING

# Read team from __DATA__ section
my (%team, %files);

while ( <DATA> ) {

    chomp;

    next if '';

    my ($alias, @details) = split /,/;
   

    $team{$alias} = $details[0];  # Name
    
    if ( @details > 2 ) {  # files translated by this team member

        $files{$_} = $alias foreach @details[2 .. $#details];

    }
}

close DATA;



# Copy work memory to clean project => clean memory
copy($MEM_PATH, $CLEANM_PATH) unless $notrev;

# Copy work memory to /memory/work in repository 
# and rename it as perlspanish-omegat.zipf.tmx
copy($MEM_PATH, $WORK_PATH) unless $notrev;



foreach my $pod_name (@names) {

    my $source    = "$SOURCE_PATH/$pod_name";     # src file in work OmegaT project
    
    unless ( -f $source ) {
        say "File $pod_name not found.";
        next;
    }

    my $target    = "$TARGET_PATH/$pod_name";     # translated file generated by OmegaT
    my $trans_pod = "$TRANSPOD_PATH/$pod_name";   # file delivered by translator
    my $rev_pod   = "$REVPOD_PATH/$pod_name";     # file delivered by reviewer
    my $clean     = "$CLEAN_PATH/$pod_name";      # src file in clean OmegaT project 

    # Get path components
    my ($name, $path, $suffix) = fileparse($target, qr{\.pod|\.pm|\..*});    

    my ( $ext ) = $suffix =~ /\.(.+)$/;

    my ( $readme, $final_name );
    if ( $name eq "README" ) {
        
        $readme++;
        say "Readme file" if $readme;

        $final_name = "perl$ext.pod";  # new name convention for READMEs in 5.16

    } else {
        
        $final_name = $pod_name;

    }
    
    my $distr  = "$DISTR_PATH/$final_name";

        
    # Check if file is perlglossary.pod and, in that case, sort alphabetically
    if ( $pod_name eq "perlglossary.pod" ) {
        
        say "Sorting perlglossary.pod...";
        sort_glossary( $target );

    }


    # Copy source file to clean project => clean memory (unless file is not reviewed)
    copy($source, $clean) unless $notrev;
        
    # Copy generated file to git archive ((unless file is not reviewed); won't go through postprocessing
    copy($target, $rev_pod) unless $notrev;

    # Copy translated file to distribution
    if ( $notrev ) {

        # copy translated file (not yet reviewed) from the repository /translated folder
        copy($trans_pod, $distr);

    } else {
        
        # copy reviewed file from OmegaT /target folder
        copy($target, $distr);

    }

    # Slurp the distribution file to implement several fixes
    open my $dirty, '<:encoding(UTF-8)', $distr; # OmegaT generates UTF-8 files
   
    my $text = do { local $/; <$dirty> };
    
    close $dirty;

    # Replace double-spaces after full-stop with single space
    $text =~ s/(?<=\.)  (?=[A-Z])/ /g; # two white spaces after full stop
    # TO DO: add more checks
    
    
    # Add a warning in case the file is not reviewed
    $text =~ s/=head1 (?:NOMBRE|NAME)\K(.+?)(?==head1 )/$1\n\n$NOT_REVIEWED\n\n/s if $notrev;

    # Check if there is a =encoding command
    my $encoding;
    if ( $text =~ /^=encoding (\S+)/m ) {

        $encoding = $1;
        if ( $encoding eq 'utf8' ) {

            say "Found UTF-8 encoding command.";

        } else {

            say "Found alternative encoding command in POD. Changing to UTF-8..."; 
            $text =~ s/^=encoding\s+$encoding/^=encoding utf8/;

        }

    } else {

        say "No encoding command found. Adding '=encoding utf8'...";
        $text = "=encoding utf8\n\n$text";

    }
    
    # Save the fixed file
    open my $fixed, ">:encoding(UTF-8)", $distr;
    
    if ( $readme ) {
     
        # Add pod formatting to the first paragraph, to help Pod::Tidy 
        print $fixed "=head1 FOO\n\n$text";

    } else {

        print $fixed $text;

    }

    close $fixed;


    # Wrap lines (OmegaT removes some line breaks) using Pod::Tidy 
    my $processed = Pod::Tidy::tidy_files(
                                            files   => [ $distr ],
                                            inplace => 1,
                                            columns => 80,
                                         );


    if ( $readme ) {
        
        # Remove added pod formatting from README files 
        open my $dirty, "<:encoding(UTF-8)", $distr;
   
        my $text = do { local $/; <$dirty> };
    
        close $dirty;


        $text =~ s/^=head1 FOO\n\n//;


        open my $fixed, ">:encoding(UTF-8)", $distr;

        print $fixed $text;

        close $fixed;
    }


    # Add TRANSLATORS section to distribution file
    open my $out, ">>:encoding(UTF-8)", $distr;

    my $translators_section =  "\n=head1 TRADUCTORES\n\n=over\n\n";
    
    my @file_team = ("explorer", "zipf"); # default team

    unshift(@file_team, $files{$name}) if $files{$name};
    
    $translators_section .= "=item * $team{$_}\n\n" foreach @file_team;
    $translators_section .= "=back\n\n";
    
    print $out $translators_section;

    close $out;


    # Check POD sintax/formatting
    say "Checking POD syntax...";
    podchecker($distr);


    # Generate word-oriented diff file
    if ( $diff && !$notrev) {  # Will not create a diff file if option $notrev is ON

        say "Generating diff file...";

        diff_file(
                    trans     => $trans_pod,
                    rev       => $rev_pod,
                    path      => $DIFF_PATH,
                    name      => $name,
                    extension => $ext,
                    header    => $DIFF_HEADER,
                 );

    }


    # Generate HTML file for proofreading;
    unless ( $nohtml ) {

        say "Generating HTML version of POD file...";
        
        my $html;

        if ($notrev) {    

            $html = "$TRANSPOD_PATH/$name$suffix.html";
        
        } else {
        
            $html = "$REVPOD_PATH/$name$suffix.html";
        
        }

        system("perl -MPod::Simple::HTML -e Pod::Simple::HTML::go $distr > $html");

    }

    unlink "$distr~";

}


sub sort_glossary {

    my $glossary_path = shift;

    open my $glos, '<:encoding(UTF-8)', $glossary_path; # OmegaT generates UTF-8 files
   
    my $text = do { local $/; <$glos> };
    
    close $glos;

    my ( $header  ) = $text =~ /^(.+?)(?==head2 A)/s;
    my ( $footer  ) = $text =~ /(=head1 AUTOR Y COPYRIGHT.+)$/s;
    my ( @entries ) = $text =~ /(=item .+?)(?==item|=back)/gs;



    my %entries;

    foreach my $entry ( @entries ) {

        my ( $term, $description ) = split /=item .+?\K\n\n/m, $entry;

        $term =~ s/=item\s+//;
        
        my $initial = unidecode(uc(substr $term, 0, 1));

        push @{$entries{$initial}}, { term => $term, description => $description };

    }

    
    # generate sorted file, overwriting original (it can always be re-generated by OmegaT...)
    my $collator = Unicode::Collate::Locale->new(locale => 'es');
    
    open my $sorted, '>:encoding(UTF-8)', $glossary_path;

    print $sorted $header;

    foreach my $letter ( sort keys %entries ) {

        print  $sorted "=head2 $letter\n\n=over 4\n\n";

        #foreach my $entry ( sort { $a->{term} cmp $b->{term} } @{ $entries{$letter} } ) {
        foreach my $entry ( sort { $collator->cmp( $a->{term}, $b->{term} ) } @{ $entries{$letter} } ) {

            print $sorted "=item ", $entry->{term}, "\n\n";
            print $sorted $entry->{description};

        }

        print $sorted "=back\n\n";

    }

    print $sorted $footer;

    close $sorted;


}


sub diff_file {

    my %params = @_;

    unless ( -e $params{trans} ) {

        say "Translated file not available in translated folder; will not generate a diff file.";
        return;

    }

    my (@trans, @rev);

    {

        local $/ = "\n\n";
    
        open my $trans, "<:encoding(UTF-8)", $params{trans};
        chomp(@trans = <$trans>);
        close $trans;

        open my $rev, "<:encoding(UTF-8)", $params{rev};
        chomp(@rev = <$rev>);
        close $rev;

    }

    my $target = "$params{path}/$params{name}_diff.html"; 

    open my $out, ">:encoding(UTF-8)", $target;

    say $out $DIFF_HEADER;
    say $out "<h1>Comparison results for $params{name}.$params{extension}</h1>\n</br>";

    for (my $i=0; $i <= $#trans; $i++) {
       
        $trans[$i] =~ s/</\(/g;
        $trans[$i] =~ s/>/\)/g;

        $rev[$i]   =~ s/</\(/g;
        $rev[$i]   =~ s/>/\)/g;
        
        if ( $rev[$i] ne $trans[$i] ) {
    
             my $diff = word_diff \$trans[$i], \$rev[$i], { STYLE => 'HTML' };

            say $out "<span style='color:blue'><b>TRANSLATOR:</b></span><br />$trans[$i]<br />";

            say $out "<span style='color:red'><b>REVIEWER:</b></span><br />$rev[$i]<br />";

            say $out "<span style='color:blueviolet'><b>CHANGES:</b></span><br />$diff<br />";        

        }

    }    
    

    close $out;

}


__DATA__
j3nnn1,Jennifer Maldonado,C< jcmm986 + POD2ES at gmail.com >
mgomez,Manuel G�mez Olmedo,C< mgomez + POD2ES at decsai.ugr.es >,perlootut,perlobj,perlmod
explorer,Joaqu�n Ferrero (Tech Lead),C< explorer + POD2ES at joaquinferrero.com >
zipf,Enrique Nell (Language Lead),C< blas.gordon + POD2ES at gmail.com >   
