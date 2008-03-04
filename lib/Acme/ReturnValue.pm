#!/usr/bin/perl
package Acme::ReturnValue;
use strict;
use warnings;
use version; our $VERSION = version->new( '0.05' );

use PPI;
use File::Find;
use Parse::CPAN::Packages;
use File::Spec::Functions;
use File::Temp qw(tempdir);
use File::Path;
use File::Copy;
use Archive::Any;
use base 'Class::Accessor';
use URI::Escape;
use Encode;

__PACKAGE__->mk_accessors(qw(interesting boring failed));

$|=1;

=head1 NAME

Acme::ReturnValue - report interesting module return values

=head1 SYNOPSIS

    use Acme::ReturnValue;
    my $rvs = Acme::ReturnValue->new;
    $rvs->in_INC;
    foreach (@{$rvs->interesting}) {
        say $_->{package} . ' returns ' . $_->{value}; 
    }

=head1 DESCRIPTION

C<Acme::ReturnValue> will list 'interesting' return values of modules. 
'Interesting' means something other than '1'.

=head2 METHODS

=cut

=head3 waste_some_cycles

    my $data = $arv->waste_some_cycles( '/some/module.pm' );

C<waste_some_cycles> parses the passed in file using PPI. It tries to 
get the last statement and extract it's value.

C<waste_some_cycles> returns a hash with following keys

=over

=item * file

The file

=item * package 

The package defintion (the first one encountered in the file

=item * value

The return value of that file

=back

C<waste_some_cycles> will also put this data structure into 
L<interesting> or L<boring>.

You might want to pack calls to C<waste_some_cycles> into an C<eval> 
because PPI dies on parse errors.

=cut

sub waste_some_cycles {
    my ($self, $file) = @_;
    my $doc = PPI::Document->new($file);

    eval {  # I don't care if that fails...
        $doc->prune('PPI::Token::Comment');
        $doc->prune('PPI::Token::Pod');
    }; 

    my @packages=$doc->find('PPI::Statement::Package');
    my $this_package;

    foreach my $node ($packages[0][0]->children) {
        if ($node->isa('PPI::Token::Word')) {
            $this_package = $node->content;
        }
    }

    my @significant = grep { _is_code($_) } $doc->schildren();
    my $match = $significant[-1];

    my $return_value=$match->content;
    $return_value=~s/;$//;

    my $data = {
        'file'    => $file,
        'package' => $this_package,
        'value'   => $return_value,
    };
    if ($return_value eq '1') {
        push(@{$self->boring},$data);
    }
    else {
        push(@{$self->interesting},$data);
    }
    return $data;
}

=head4 _is_code

Stolen directly from Perl::Critic::Policy::Modules::RequireEndWithOne
as suggested by Chris Dolan.

Thanks!

=cut

sub _is_code {
    my $elem = shift;
    return ! (    $elem->isa('PPI::Statement::End')
               || $elem->isa('PPI::Statement::Data'));
}

=head3 new

    my $arc = Acme::ReturnValue->new;

Yet another boring constructor;

=cut

sub new {
    my ($class,$opts) = @_;
    $opts ||= {};
    my $self=bless $opts,$class;
    $self->interesting([]);
    $self->boring([]);
    $self->failed([]);
    return $self;
}

=head3 in_CPAN

=cut

sub in_CPAN {
    my ($self,$cpan,$out)=@_;

    my $p=Parse::CPAN::Packages->new(catfile($cpan,qw(modules 02packages.details.txt.gz)));

    if (!-d $out) {
        mkpath($out) || die "cannot make dir $out";
    }

    foreach my $dist (sort {$a->dist cmp $b->dist} $p->latest_distributions) {
        my $data;
        my $distfile = catfile($cpan,'authors','id',$dist->prefix);
        print "$distfile\n";
        $data->{file}=$distfile;
        my $dir;
        eval {
            $dir = tempdir('/var/tmp/arv_XXXXXX');
        
            my $archive=Archive::Any->new($distfile);
            $archive->extract($dir);
            my $outname=catfile($out,$dist->distvname.".dump");
            system("$^X $0 --dir $dir > $outname");
        };
        if ($@) {
            print $@;
            $data->{error}=$@;
            push (@{$self->failed},$data);
        }
        rmtree($dir);
    }
}

=head3 in_INC

    $arv->in_INC;

Collect return values from all F<*.pm> files in C<< @INC >>.

=cut

sub in_INC {
    my $self=shift;
    foreach my $dir (@INC) {
        $self->in_dir($dir);
    }
}

=head3 in_dir

    $arv->in_dir( $some_dir );

Collect return values from all F<*.pm> files in C<< $dir >>.

=cut

sub in_dir {
    my ($self,$dir)=@_;
    
    my @pms;
    find(sub {
        return unless /\.pm\z/;
        return if /^x?t\//;
        push(@pms,$File::Find::name);
    },$dir);

    foreach my $pm (@pms) {
        $self->in_file($pm);
    }
}

=head3 in_file

    $arv->in_file( $some_file );

Collect return value from the passed in file.

If L<waste_some_cycles> failed, puts information on the failing file into L<failed>.

=cut

sub in_file {
    my ($self,$file)=@_;
    eval { $self->waste_some_cycles($file) };
    if ($@) {
        push (@{$self->failed},{file=>$file,error=>$@});
    }
}

=head3 generate_report_from_dump

    $arv->generate_report_from_dump($dir);

Get all Dump-Files in C<$dir>, eval them, and generate a HTML page 
with the results.

Will print directly to STDOUT, because I'm lazy ATM..

=cut

sub generate_report_from_dump {
    my ($self,$in)=@_;

    my @interesting;
    opendir(DIR,$in) || die "Cannot open dir $in: $!";
    while (my $file=readdir(DIR)) {
        next unless $file=~/^(.*)\.dump$/;
        my $dist=$1;

        my $rv;
        $rv=do(catfile($in,$file));
        my $interesting=$rv->interesting;
        next unless @$interesting > 0;
        push(@interesting,$interesting);
    }

    my $now=scalar localtime;
    print <<"EOHTML";
<html>
<head><title>Acme::ReturnValue findings</title>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=utf-8">
</head>

<body><h1>Acme::ReturnValue findings</h1>

<p>Acme::ReturnValue: <a href="http://search.cpan.org/dist/Acme-ReturnValue">on CPAN</a> | <a href="http://domm.plix.at/talks/acme_returnvalue.html">talks about it</a><br>
Contact: domm  AT cpan.org<br>
Generated: $now
</p>

<table>
<tr><td>Module</td><td>Return Value</td></tr>
EOHTML
    
    foreach my $metayay (@interesting) {
        foreach my $yay (@$metayay) {
            my $val=$yay->{value};
            $val=~s/>/&gt;/g;
            $val=~s/</&lt;/g;
            print "<tr><td>".$yay->{package}."</td><td>".encode('utf8',decode('latin1',$val))."</td></tr>\n";
        }
    }

    print "</table></body></html>";


}


"let's return a strange value";

__END__

=head3 interesting

Returns an ARRAYREF containing 'interesting' modules.

=head3 boring

Returns an ARRAYREF containing 'boring' modules.

=head3 failed

Returns an ARRAYREF containing unparsable modules.

=pod

=head1 BUGS

Probably many, because I'm not sure I master PPI yet.

=head1 AUTHOR

Thomas Klausner, C<< <domm@cpan.org> >>

Thanks to Armin Obersteiner and Josef Schmid for input during very 
early development

=head1 BUGS

Please report any bugs or feature requests to
C<bug-acme-returnvalue@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.  I will be notified, and then you'll automatically
be notified of progress on your bug as I make changes.

=head1 COPYRIGHT & LICENSE

Copyright 2008 Thomas Klausner

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
