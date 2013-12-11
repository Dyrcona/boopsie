#!/usr/bin/perl
# ---------------------------------------------------------------
# Copyright © 2013 Merrimack Valley Library Consortium
# Jason Stephenson <jstephenson@mvlc.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# ---------------------------------------------------------------

use XML::XPath;

package Boopsie;

Boopsie::Email->init();
Boopsie::Export->init();
Boopsie::Upload->init();

Boopsie::Export->export();

package Boopsie::Email;
use Module::Load;
use MIME::Lite;
use JSONPrefs;

my $prefs;
my $module;

sub init {
    $prefs = JSONPrefs->load($ENV{HOME} . '/myprefs.d/smtp.json');
    $module = "Net::SMTP";
    if ($prefs->encryption) {
        $module = "Net::SMTP::TLS" if ($prefs->encryption =~ /^tls$/i);
        $module = "Net::SMTP::SSL" if ($prefs->encryption =~ /^ssl$/i);
    }
    load $module;
}

sub send {
    my $package = shift;
    my $subject = shift;
    my $message = shift;
    my $recips = shift;

    my $emailTo = "";
    foreach my $to (@{$recips}) {
        $emailTo .= ", " if (length($emailTo));
        $emailTo .= $to;
    }

    my $emailFrom = $prefs->from->email;
    $emailFrom = $prefs->from->name . ' <' . $prefs->from->email . '>' if ($prefs->from->name);

    my $msg = MIME::Lite->new(From => $emailFrom,
                              To => $emailTo,
                              Subject => $subject,
                              Data => $message);
    # I want to figure out a way to pass the Port, User, and Password
    # options in as some kind of hash or hashref, but the two obvious
    # methods that I've tried have not worked.
    my $smtp = $module->new($prefs->host,
                            Port => $prefs->port,
                            User => $prefs->user,
                            Password => $prefs->password);
    $smtp->mail($prefs->from->email);
    foreach my $recipient (@{$recips}) {
        $smtp->to($recipient);
    }
    $smtp->data;
    $smtp->datasend($msg->as_string);
    $smtp->dataend;
    $smtp->quit;
}

package Boopsie::Export;
use DBI;
use Encode;
use MARC::File;
use MARC::File::XML;
use MARC::Record;
use Archive::Zip;
use File::Basename;

my %opts;

sub init {
    my $xpath = XML::XPath->new(filename => "export.xml");
    my $e = 0;
    foreach my $emailTo ($xpath->findnodes("/export/emailTo")) {
        $opts{emailTo}->[$e++] = $xpath->findvalue("text()", $emailTo)->value();
    }
    $opts{emailCount} = $e;
    $opts{directory} = $xpath->findvalue("/export/files/working_directory")->value();
    $opts{delete} = $xpath->exists("/export/files/delete_files");
    $opts{dbhost} = $xpath->findvalue("/export/database/host")->value();
    $opts{dbport} = $xpath->findvalue("/export/database/port")->value();
    $opts{database} = $xpath->findvalue("/export/database/database")->value();
    $opts{dbuser} = $xpath->findvalue("/export/database/user")->value();
    $opts{dbpass} = $xpath->findvalue("/export/database/password")->value();
}

sub export {
    my $query =<<'    QUERY';
select id, marc
from biblio.record_entry
where deleted = 'f'
and id > -1
order by id
    QUERY

    my $dsn = 'dbi:Pg:';
    $dsn .= 'database=' . $opts{database};
    $dsn .= ';host=' . $opts{dbhost} if ($opts{dbhost});
    $dsn .= ';port=' . $opts{dbport} if ($opts{dbport});

    my $dbh = DBI->connect($dsn, $opts{dbuser}, $opts{dbpass});
    if ($dbh) {
        my $filename = $opts{directory} . (($opts{directory} !~ /\/$/) ? '/' : '') . 'bibs.mrc';
        if (open(OUT, ">:utf8", $filename)) {
            my $sth = $dbh->prepare($query);
            $sth->execute;
            while (my $data = $sth->fetchrow_hashref) {
                my $record = MARC::Record->new_from_xml($data->{marc}, 'UTF-8');
                print(OUT $record->as_usmarc());
            }
            close(OUT);
            my $archivename = $opts{directory} . (($opts{directory} !~ /\/$/) ? '/' : '') . 'bibs.zip';
            my $archive = Archive::Zip->new();
            my $member = $archive->addFile($filename, basename($filename));
            $member->desiredCompressionMethod( COMPRESSION_DEFLATED );
            $member->desiredCompressionLevel(9);
            if ($archive->writeToFileNamed($archivename) == AZ_OK) {
                Boopsie::Upload->upload([$archivename]);
            }
            if ($opts{delete}) {
                unlink $filename;
                unlink $archivename;
            }
        }
        else {
            Boopsie::Email->send('Boopsie Error', "Failed to create $filename", $opts{emailTo});
            exit(1);
        }
            $dbh->disconnect;
    }
    else {
        Boopsie::Email->send('Boopsie Error', "Failed to connect to $dsn", $opts{emailTo});
        exit(1);
    }
}

package Boopsie::Upload;

use Net::FTP;
use File::Basename;

my %opts;

sub init {
    my $xpath = XML::XPath->new(filename => "ftp.xml");
    foreach my $site ($xpath->findnodes("/ftp/site")) {
        my $id = $xpath->findvalue("attribute::id", $site)->value();
        $opts{$id}{host} = $xpath->findvalue("//host", $site)->value();
        $opts{$id}{user} = $xpath->findvalue("//user", $site)->value();
        $opts{$id}{password} = $xpath->findvalue("//password", $site)->value();
        $opts{$id}{cwd} = $xpath->findvalue("//cwd", $site)->value();
        $opts{$id}{passive} = $xpath->exists("//passive", $site);
        my $e = 0;
        foreach my $emailTo ($xpath->findnodes("//emailTo", $site)) {
            $opts{$id}{emailTo}->[$e++] = $xpath->findvalue("text()", $emailTo)->value();
        }
        $opts{$id}{emailCount} = $e;
        $e = 0;
        foreach my $emailTo ($xpath->findnodes("//emailTo[\@onError='1']", $site)) {
            $opts{$id}{errorTo}->[$e++] = $xpath->findvalue("text()", $emailTo)->value();
        }
        $opts{$id}{errorCount} = $e;
    }
}

sub upload {
    my $package = shift;
    my $files = shift;
    foreach my $site (keys %opts) {
        my $ftp = Net::FTP->new($opts{$site}{host}, Passive => $opts{$site}{passive} ? 1 : 0);
        if ($ftp) {
            # Hold any potential error messages.
            my $message;
            unless ($ftp->login($opts{$site}{user}, $opts{$site}{password})) {
                $message = "Failed to login to " . $opts{$site}{host} . "\n";
                $message .= "\n" . $ftp->message . "\n";
                Boopsie::Email->send('Boopsie FTP Error', $message, $opts{$site}{errorTo});
                return;
            }
            if ($opts{$site}{cwd}) {
                unless ($ftp->cwd($opts{$site}{cwd})) {
                    $message = "Failed to cwd to " . $opts{$site}{cwd} . " on " . $opts{$site}{host} . "\n";
                    $message .= "\n" . $ftp->message . "\n";
                    Boopsie::Email->send('Boopsie FTP Error', $message, $opts{$site}{errorTo});
                    return;
                }
            }
            foreach my $file ($ftp->dir) {
                $ftp->delete($file);
            }
            $ftp->binary;
            foreach my $file (@$files) {
                unless (defined $ftp->put($file, basename($file))) {
                    $message = "Failed to put file $file " . (($opts{$site}{cwd}) ? "to " . $opts{$site}{cwd} : "") . " on " . $opts{$site}{host} . "\n";
                    $message .= "\n" . $ftp->message . "\n";
                    Boopsie::Email->send('Boopsie FTP Error', $message, $opts{$site}{errorTo});
                    return;
                }
            }
            $ftp->quit;
            $message = "The following file(s) were uploaded to " . $opts{$site}{host} . (($opts{$site}{cwd}) ? " in " . $opts{$site}{cwd} : '') . ":\n";
            foreach my $file (@$files) {
                $message .= basename($file);

            }
            Boopsie::Email->send('Boopsie Files Uploaded', $message, $opts{$site}{emailTo});
        }
        else {
            my $message = 'Failed to connect to ' . $opts{$site}{host} . "\n";
            Boopsie::Email->send('Boopsie Error', $message, $opts{$site}{errorTo});
        }
    }
}

1;
