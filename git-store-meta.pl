#!/usr/bin/perl -w
# =============================================================================
# Usage: git-store-meta.pl ACTION [OPTION...]
# Store, update, or apply metadata for files revisioned by Git.
#
# ACTION is one of:
#   -s|--store         Store the metadata for all files revisioned by Git.
#   -u|--update        Update the metadata for changed files.
#   -a|--apply         Apply the stored metadata to files in the working tree.
#   -i|--install       Install hooks in this repo for automated update/apply.
#                      (pre-commit, post-checkout, and post-merge)
#   -h|--help          Print this help and exit.
#
# Available OPTIONs are:
#   -f|--fields FIELDs Fields to handle (see below). If omitted, fields in the
#                      current metadata store file are picked if possible;
#                      otherwise, "mtime" is picked as the default.
#                      (available for: --store, --apply)
#   -n|--dry-run       Run a test and print the output, without real action.
#                      (available for: --store, --update, --apply)
#   -v|--verbose       Apply with verbose output.
#                      (available for: --apply)
#   --force            Force an apply even if the working tree is not clean. Or
#                      install hooks and overwrite existing ones.
#                      (available for: --apply, --install)
#   -t|--target FILE   Specify another filename to store metadata. Defaults to
#                      ".git_store_meta" in the root of the working tree.
#                      (available for: --store, --update, --apply, --install)
#
# FIELDs is a comma-separated string consisting of the following values:
#   mtime      last modified time
#   atime      last access time
#   mode       Unix permissions
#   user       user name
#   group      group name
#   uid        user ID (if user is also set, prefer user and fallback to uid)
#   gid        group ID (if group is also set, prefer group and fallback to gid)
#   acl        access control lists for POSIX setfacl/getfacl
#   directory  include directories
#
# git-store-meta 2.0.0_003
# Copyright (c) 2015-2019, Danny Lin
# Released under MIT License
# Project home: https://github.com/danny0838/git-store-meta
# =============================================================================

use utf8;
use strict;

use version; our $VERSION = version->declare("v2.0.0_003");
use Getopt::Long;
Getopt::Long::Configure qw(gnu_getopt);
use Cwd;
use File::Basename;
use File::Copy qw(copy);
use File::Spec::Functions qw(rel2abs abs2rel);
use POSIX qw(strftime);
use Time::Local;

# define constants
my $GIT_STORE_META_PREFIX    = "# generated by";
my $GIT_STORE_META_APP       = "git-store-meta";
my $GIT_STORE_META_FILENAME  = ".git_store_meta";
my $GIT                      = "git";

# runtime variables
my $script = rel2abs(__FILE__);
my $action;
my $gitdir;
my $topdir;
my $git_store_meta_filename;
my $git_store_meta_file;
my $git_store_meta_header;
my $temp_file;
my $cache_file_exist = 0;
my $cache_file_accessible = 0;
my $cache_header_valid = 0;
my $cache_app;
my $cache_version;
my @cache_fields;

# parse arguments
my %argv = (
    "store"      => 0,
    "update"     => 0,
    "apply"      => 0,
    "install"    => 0,
    "help"       => 0,
    "target"     => undef,
    "fields"     => undef,
    "force"      => 0,
    "dry-run"    => 0,
    "verbose"    => 0,
);
GetOptions(
    "store|s"    => \$argv{'store'},
    "update|u"   => \$argv{'update'},
    "apply|a"    => \$argv{'apply'},
    "install|i"  => \$argv{'install'},
    "help|h"     => \$argv{'help'},
    "fields|f=s" => \$argv{'fields'},
    "force"      => \$argv{'force'},
    "dry-run|n"  => \$argv{'dry-run'},
    "verbose|v"  => \$argv{'verbose'},
    "target|t=s" => \$argv{'target'},
);

# determine action
# priority: help > install > update > store > action if multiple assigned
for ('help', 'install', 'update', 'store', 'apply') {
    if ($argv{$_}) { $action = $_; last; }
}

# handle action: help, and unknown
if (!defined($action)) {
    usage();
    exit 1;
}
elsif ($action eq "help") {
    usage();
    exit 0;
}

# init and validate gitdir
$gitdir = `$GIT rev-parse --git-dir 2>/dev/null`
    or die "error: unknown git repository.\n";
chomp($gitdir);

# handle action: install
if ($action eq "install") {
    print "installing hooks...\n";
    install_hooks();
    exit 0;
}

# init and validate topdir
$topdir = `$GIT rev-parse --show-cdup 2>/dev/null`
    or die "error: current working directory is not in a git working tree.\n";
chomp($topdir);

# record the original CWD before change
my $cwd = cwd();

# cd to the top level directory of current git repo
if ($topdir) {
  chdir($topdir);
}

# init paths and header info
$git_store_meta_filename = defined($argv{'target'}) ? $argv{'target'} : $GIT_STORE_META_FILENAME;
$git_store_meta_file = rel2abs($git_store_meta_filename);
$temp_file = $git_store_meta_file . ".tmp" . time;
get_cache_header_info();

# handle action: store, update, apply

# validate
if ($action eq "store") {
    print "storing metadata to `$git_store_meta_file' ...\n";
}
elsif ($action eq "update") {
    print "updating metadata to `$git_store_meta_file' ...\n";

    if (!$cache_file_exist) {
        die "error: `$git_store_meta_file' doesn't exist.\nRun --store to create new.\n";
    }
    if (!$cache_file_accessible) {
        die "error: `$git_store_meta_file' is not an accessible file.\n";
    }
    if (!$cache_header_valid) {
        die "error: `$git_store_meta_file' is malformatted.\nFix it or run --store to create new.\n";
    }
    if ($cache_app ne $GIT_STORE_META_APP) {
        die "error: `$git_store_meta_file' is using an unknown schema: $cache_app $cache_version\nFix it or run --store to create new.\n";
    }
    if (!(1.1.0 <= $cache_version && $cache_version < 2.1.0)) {
        die "error: `$git_store_meta_file' is using an unsupported version: $cache_version\n";
    }
}
elsif ($action eq "apply") {
    print "applying metadata from `$git_store_meta_file' ...\n";

    if (!$cache_file_exist) {
        print "`$git_store_meta_file' doesn't exist, skipped.\n";
        exit;
    }
    if (!$argv{'force'} && `$GIT status --porcelain -uno -z 2>/dev/null` ne "") {
      die "error: git working tree is not clean.\nCommit, stash, or revert changes before running this, or add --force.\n";
    }
    if (!$cache_file_accessible) {
        die "error: `$git_store_meta_file' is not an accessible file.\n";
    }
    if (!$cache_header_valid) {
        die "error: `$git_store_meta_file' is malformatted.\n";
    }
    if ($cache_app ne $GIT_STORE_META_APP) {
        die "error: `$git_store_meta_file' is using an unknown schema: $cache_app $cache_version\n";
    }
}

# init fields and output header
my @fields = get_fields();
$git_store_meta_header = join("\t", $GIT_STORE_META_PREFIX, $GIT_STORE_META_APP, substr($VERSION, 1)) . "\n";

# show settings
print "fields: " . join(", ", @fields) . "\n";

# do the action
if ($action eq "store") {
    if (!$argv{'dry-run'}) {
        open(GIT_STORE_META_FILE, '>', $git_store_meta_file)
            or die "error: failed to write to `$git_store_meta_file': $!\n";
        select(GIT_STORE_META_FILE);
        store(@fields);
        close(GIT_STORE_META_FILE);
        select(STDOUT);
    }
    else {
        store(@fields);
    }
}
elsif ($action eq "update") {
    # copy the cache file to the temp file
    # to prevent a conflict in further operation
    open(GIT_STORE_META_FILE, "<", $git_store_meta_file)
        or die "error: failed to access `$git_store_meta_file': $!\n";
    open(TEMP_FILE, ">", $temp_file) or die;
    my $count = 0;
    while (<GIT_STORE_META_FILE>) {
        if (++$count <= 2) { next; }  # discard first 2 lines
        print TEMP_FILE;
    }
    close(TEMP_FILE);
    close(GIT_STORE_META_FILE);

    # update cache
    if (!$argv{'dry-run'}) {
        open(GIT_STORE_META_FILE, '>', $git_store_meta_file)
            or die "error: failed to write to `$git_store_meta_file': $!\n";
        select(GIT_STORE_META_FILE);
        update(@fields);
        close(GIT_STORE_META_FILE);
        select(STDOUT);
    }
    else {
        update(@fields);
    }

    # clean up
    my $clear = unlink($temp_file);
}
elsif ($action eq "apply") {
    apply(@fields);
}

# -----------------------------------------------------------------------------

sub get_file_type {
    my ($file) = @_;
    if (-l $file) {
        return "l";
    }
    elsif (-f $file) {
        return "f";
    }
    elsif (-d $file) {
        return "d";
    }
    return undef;
}

sub timestamp_to_gmtime {
    my ($timestamp) = @_;
    my @t = gmtime($timestamp);
    return strftime("%Y-%m-%dT%H:%M:%SZ", @t);
}

sub gmtime_to_timestamp {
    my ($gmtime) = @_;
    $gmtime =~ m!^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$!;
    return timegm($6, $5, $4, $3, $2 - 1, $1);
}

# escape a string to be safe to use as a shell script argument
sub escapeshellarg {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# escape special chars in a filename to be safe to stay in the data file
sub escape_filename {
    my ($str) = @_;
    $str =~ s!([\x00-\x1F\x5C\x7F])!'\x'.sprintf("%02X", ord($1))!eg;
    return $str;
}

# reverse of escape_filename
# "\\" is left for backward compatibility with versions < 1.1.4
sub unescape_filename {
    my ($str) = @_;
    $str =~ s!\\(?:x([0-9A-Fa-f]{2})|\\)!$1?chr(hex($1)):"\\"!eg;
    return $str;
}

# Print the initial comment block, from first to second "# ==",
# with "# " removed
sub usage {
    my $start = 0;
    open(GIT_STORE_META, "<", $script)
        or die "error: failed to access `$script': $!\n";
    while (my $line = <GIT_STORE_META>) {
        if ($line =~ m!^# ={2,}!) {
            if (!$start) { $start = 1; next; }
            else { last; }
        }
        if ($start) {
            $line =~ s/^# ?//;
            print $line;
        }
    }
    close(GIT_STORE_META);
}

# Install hooks
sub install_hooks {
    # Ensure hook files don't exist unless --force
    if (!$argv{'force'}) {
        my $err = '';
        foreach my $n ("pre-commit", "post-checkout", "post-merge") {
            my $f = "$gitdir/hooks/$n";
            if (-e "$f") {
                $err .= "error: hook file `$f' already exists.\n";
            }
        }
        if ($err) { die $err . "Add --force to overwrite current hook files.\n"; }
    }

    # Install the hooks
    my $mask = umask; if (!defined($mask)) { $mask = 0022; }
    my $mode = 0777 & ~$mask;
    my $t;
    my $f = defined($argv{'target'}) ? " -t " . escapeshellarg($argv{'target'}) : "";
    my $f2 = escapeshellarg(defined($argv{'target'}) ? $argv{'target'} : $GIT_STORE_META_FILENAME);

    $t = "$gitdir/hooks/pre-commit";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $f2, $f, $f, $f2;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/git-store-meta.pl
[ ! -x "$script" ] && script=git-store-meta.pl

# update (or store as fallback) the cache file if it exists
if [ -f %s ]; then
    "$script" --update%s ||
    "$script" --store%s ||
    exit 1

    # remember to add the updated cache file
    git add %s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";

    $t = "$gitdir/hooks/post-checkout";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $f;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/git-store-meta.pl
[ ! -x "$script" ] && script=git-store-meta.pl

sha_old=$1
sha_new=$2
change_br=$3

# apply metadata only when HEAD is changed
if [ ${sha_new} != ${sha_old} ]; then
    "$script" --apply%s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";

    $t = "$gitdir/hooks/post-merge";
    open(FILE, '>', $t) or die "error: failed to write to `$t': $!\n";
    printf FILE <<'EOF', $f;
#!/bin/sh
# when running the hook, cwd is the top level of working tree

script=$(dirname "$0")/git-store-meta.pl
[ ! -x "$script" ] && script=git-store-meta.pl

is_squash=$1

# apply metadata after a successful non-squash merge
if [ $is_squash -eq 0 ]; then
    "$script" --apply%s
fi
EOF
    close(FILE);
    chmod($mode, $t) == 1 or die "error: failed to set permissions on `$t': $!\n";
    print "created `$t'\n";
}

# return the header and fields info of a file
#
# @global $git_store_meta_file
# @global $cache_file_exist
# @global $cache_file_accessible
# @global $cache_header_valid
# @global $cache_app
# @global $cache_version
# @global $cache_fields
sub get_cache_header_info {
    -e $git_store_meta_file or return;
    $cache_file_exist = 1;

    -f $git_store_meta_file and open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or return;
    $cache_file_accessible = 1;

    # first line: retrieve the header
    my $line = <GIT_STORE_META_FILE>;
    $line or return;
    chomp($line);
    my ($prefix, $app, $version) = split("\t", $line);
    $prefix eq $GIT_STORE_META_PREFIX or return;
    $cache_app = $app;
    eval { $cache_version = version->parse("v" . $version); } or return;

    # second line: retrieve the fields
    $line = <GIT_STORE_META_FILE>;
    $line or return;
    chomp($line);
    foreach (split("\t", $line)) {
        m!^<(.*)>$! and push(@cache_fields, $1) or return;
    }

    # check for existence of "file" and "type" fields
    grep { $_ eq 'file' } @cache_fields or return;
    grep { $_ eq 'type' } @cache_fields or return;

    close(GIT_STORE_META_FILE);
    $cache_header_valid = 1;
}

# @global $git_store_meta_file
sub has_directory_entry {
    open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;
    my $count = 0;
    while (my $line = <GIT_STORE_META_FILE>) {
        if (++$count <= 2) { next; }  # discard first 2 lines
        $line =~ s/^\s+//; $line =~ s/\s+$//;
        next if $line eq "";

        # for each line, parse the record
        if ((split("\t", $line))[1] eq "d") {
            return 1;
        }
    }
    return 0;
}

# @global $argv
# @global $action
# @global $cache_header_valid
# @global $cache_version
sub get_fields {
    my %fields_used = (
        "file"  => 0,
        "type"  => 0,
        "mtime" => 0,
        "atime" => 0,
        "mode"  => 0,
        "uid"   => 0,
        "gid"   => 0,
        "user"  => 0,
        "group" => 0,
        "acl"   => 0,
        "directory" => 0,
    );

    # use $argv{'fields'} if defined, or use fields in the cache file
    # special handling for --update, which must use fields in the cache file
    my @parts;
    if (defined($argv{'fields'}) && $action ne "update") {
        push(@parts, ("file", "type"), split(/,\s*/, $argv{'fields'}));
    }
    elsif ($cache_header_valid) {
        @parts = @cache_fields;

        # Versions < 2 use --directory rather than --field directory
        # Add "directory" field if a directory entry exists.
        if ($cache_version < 2) {
            if (has_directory_entry()) {
                push(@parts, "directory");
            }
        }
    }
    else {
        @parts = ("file", "type", "mtime");
    }

    # remove undefined and/or duplicated fields
    my @fields;
    foreach (@parts) {
        if (exists($fields_used{$_}) && !$fields_used{$_}) {
            $fields_used{$_} = 1;
            push(@fields, $_);
        }
    }

    return @fields;
}

sub get_file_metadata {
    my ($file, $fields) = @_;
    my @fields = @{$fields};

    my @rec;
    my $type = get_file_type($file);
    return @rec if !$type;  # skip unsupported "file" types
    my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks) = lstat($file);
    my ($user) = getpwuid($uid);
    my ($group) = getgrgid($gid);
    $mtime = timestamp_to_gmtime($mtime);
    $atime = timestamp_to_gmtime($atime);
    $mode = sprintf("%04o", $mode & 07777);
    $mode = "0664" if $type eq "l";  # symbolic do not apply mode, but use 0664 if checked out as a plain file
    my $cmd = join(" ", ("getfacl", "-cE", escapeshellarg("./$file"), "2>/dev/null"));
    my $acl = `$cmd`; $acl =~ s/\n+$//; $acl =~ s/\n/,/g;
    my %data = (
        "file"  => escape_filename($file),
        "type"  => $type,
        "mtime" => $mtime,
        "atime" => $atime,
        "mode"  => $mode,
        "uid"   => $uid,
        "gid"   => $gid,
        "user"  => $user,
        "group" => $group,
        "acl"   => $acl,
        "directory"   => "",
    );
    # output formatted data
    foreach (@fields) {
        push(@rec, defined($data{$_}) ? $data{$_} : "");
    }
    return @rec;
}

sub store {
    my @fields = @_;
    my %fields_used = map { $_ => 1 } @fields;

    # read the file list and write retrieved metadata to a temp file
    open(TEMP_FILE, ">", $temp_file) or die;
    list: {
        # set input record separator for chomp
        local $/ = "\0";
        open(CMD, "$GIT ls-files -z |") or die;
        while(<CMD>) {
            chomp;
            next if $_ eq $git_store_meta_filename;  # skip data file
            my $s = join("\t", get_file_metadata($_, \@fields));
            print TEMP_FILE "$s\n" if $s;
        }
        close(CMD);
        if ($fields_used{'directory'}) {
            open(CMD, "$GIT ls-tree -rd --name-only -z \$($GIT write-tree) |") or die;
            while(<CMD>) {
                chomp;
                my $s = join("\t", get_file_metadata($_, \@fields));
                print TEMP_FILE "$s\n" if $s;
            }
            close(CMD);
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    open(CMD, "LC_COLLATE=C sort <".escapeshellarg($temp_file)." |") or die;
    while (<CMD>) { print; }
    close(CMD);

    # clean up
    my $clear = unlink($temp_file);
}

sub update {
    my @fields = @_;
    my %fields_used = map { $_ => 1 } @fields;

    # append new entries to the temp file
    open(TEMP_FILE, ">>", $temp_file) or die;
    list: {
        # set input record separator for chomp
        local $/ = "\0";
        # go through the diff list and append entries
        open(CMD, "$GIT diff --name-status --cached --no-renames -z |") or die;
        while(my $stat = <CMD>) {
            chomp($stat);
            my $file = <CMD>;
            chomp($file);
            if ($stat eq "M") {
                # a modified file
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
            }
            elsif ($stat eq "A") {
                # an added file
                print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                # mark ancestor directories as modified
                if ($fields_used{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
                    while ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                        pop(@parts);
                    }
                }
            }
            elsif ($stat eq "D") {
                # a deleted file
                print TEMP_FILE escape_filename($file)."\0\0D\0\n";
                # mark ancestor directories as deleted (temp and revertable)
                # mark parent directory as modified
                if ($fields_used{'directory'}) {
                    my @parts = split("/", $file);
                    pop(@parts);
                    if ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\2M\0\n";
                    }
                    while ($#parts >= 0) {
                        $file = join("/", @parts);
                        print TEMP_FILE escape_filename($file)."\0\0D\0\n";
                        pop(@parts);
                    }
                }
            }
        }
        close(CMD);
        # add all directories as a placeholder, which prevents deletion
        if ($fields_used{'directory'}) {
            open(CMD, "$GIT ls-tree -rd --name-only -z \$($GIT write-tree) |") or die;
            while(<CMD>) { chomp; print TEMP_FILE "$_\0\1H\0\n"; }
            close(CMD);
        }
    }
    close(TEMP_FILE);

    # output sorted entries
    print $git_store_meta_header;
    print join("\t", map {"<" . $_ . ">"} @fields) . "\n";
    my $cur_line = "";
    my $cur_file = "";
    my $cur_stat = "";
    my $last_file = "";
    open(CMD, "LC_COLLATE=C sort <".escapeshellarg($temp_file)." |") or die;
    # Since sorted, same paths are grouped together, with the changed entries
    # sorted prior.
    # We print the first seen entry and skip subsequent entries with a same
    # path, so that the original entry is overwritten.
    while ($cur_line = <CMD>) {
        chomp($cur_line);
        if ($cur_line =~ m!\x00[\x00-\x02]+(\w+)\x00!) {
            # has mark: a changed entry line
            $cur_stat = $1;
            $cur_line =~ s!\x00[\x00-\x02]+\w+\x00!!;
            $cur_file = $cur_line;
            if ($cur_stat eq "D") {
                # a delete => clear $cur_line so that this path is not printed
                $cur_line = "";
            }
            elsif ($cur_stat eq "H") {
                # a placeholder => revert previous "delete"
                # This is after a delete (optionally) and before a modify or
                # no-op line (must). We clear $last_file so the next line will
                # see a "path change" and be printed.
                $last_file = "";
                next;
            }
        }
        else {
            # a no-op line
            $cur_stat = "";
            ($cur_file) = split("\t", $cur_line);
            $cur_line .= "\n";
        }

        # print for a new file
        if ($cur_file ne $last_file) {
            if ($cur_stat eq "M") {
                # a modify => retrieve file metadata to print
                if ($cur_file eq $git_store_meta_filename) {
                    # skip data file
                    $cur_line = "";
                }
                else {
                    my $s = join("\t", get_file_metadata(unescape_filename($cur_file), \@fields));
                    $cur_line = $s ? "$s\n" : "";
                }
            }
            print $cur_line;
            $last_file = $cur_file;
        }
    }
    close(CMD);
}

# @global @cache_fields
# @global $cache_version
sub apply {
    my @fields = @_;
    my %fields_used = map { $_ => 1 } @fields;

    # v1.0.0 ~ v2.0.* share same apply procedure
    # (files with a bad file name recorded in 1.0.* will be skipped)
    if (1.0.0 <= $cache_version && $cache_version < 2.1.0) {
        my $count = 0;
        open(GIT_STORE_META_FILE, "<", $git_store_meta_file) or die;
        while (my $line = <GIT_STORE_META_FILE>) {
            ++$count <= 2 && next;  # skip first 2 lines (header)
            $line =~ s/^\s+//; $line =~ s/\s+$//;
            next if $line eq "";

            # for each line, parse the record
            my @rec = split("\t", $line);
            my %data;
            for (my $i=0; $i<=$#cache_fields; $i++) {
                $data{$cache_fields[$i]} = $rec[$i];
            }

            # check for existence and type
            my $File = $data{'file'};  # escaped version, for printing
            my $file = unescape_filename($File);  # unescaped version, for using
            next if $file eq $git_store_meta_filename;  # skip data file
            if (! -e $file && ! -l $file) {  # -e tests symlink target instead of the symlink itself
                warn "warn: `$File' does not exist, skip applying metadata\n";
                next;
            }
            my $type = $data{'type'};
            # a symbolic link could be checked out as a plain file, simply see them as equal
            if ($type eq "f" || $type eq "l" ) {
                if (! -f $file && ! -l $file) {
                    warn "warn: `$File' is not a file, skip applying metadata\n";
                    next;
                }
            }
            elsif ($type eq "d") {
                if (! -d $file) {
                    warn "warn: `$File' is not a directory, skip applying metadata\n";
                    next;
                }
                if (!$fields_used{'directory'}) {
                    next;
                }
            }
            else {
                warn "warn: `$File' is recorded as an unknown type, skip applying metadata\n";
                next;
            }

            # apply metadata
            my $check = 0;
            set_user: {
                if ($fields_used{'user'} && $data{'user'} ne "") {
                    my $uid = (getpwnam($data{'user'}))[2];
                    my $gid = (lstat($file))[5];
                    print "`$File' set user to '$data{'user'}'\n" if $argv{'verbose'};
                    if (defined $uid) {
                        if (!$argv{'dry-run'}) {
                            if (! -l $file) { $check = chown($uid, $gid, $file); }
                            else {
                                my $cmd = join(" ", ("chown", "-h", escapeshellarg($data{'user'}), escapeshellarg("./$file"), "2>&1"));
                                `$cmd`; $check = ($? == 0);
                            }
                        }
                        else { $check = 1; }
                        warn "warn: `$File' cannot set user to '$data{'user'}'\n" if !$check;
                        last set_user if $check;
                    }
                    else {
                        warn "warn: $data{'user'} is not a valid user.\n";
                    }
                }
                if ($fields_used{'uid'} && $data{'uid'} ne "") {
                    my $uid = $data{'uid'};
                    my $gid = (lstat($file))[5];
                    print "`$File' set uid to '$uid'\n" if $argv{'verbose'};
                    if (!$argv{'dry-run'}) {
                        if (! -l $file) { $check = chown($uid, $gid, $file); }
                        else {
                            my $cmd = join(" ", ("chown", "-h", escapeshellarg($uid), escapeshellarg("./$file"), "2>&1"));
                            `$cmd`; $check = ($? == 0);
                        }
                    }
                    else { $check = 1; }
                    warn "warn: `$File' cannot set uid to '$uid'\n" if !$check;
                }
            }
            set_group: {
                if ($fields_used{'group'} && $data{'group'} ne "") {
                    my $uid = (lstat($file))[4];
                    my $gid = (getgrnam($data{'group'}))[2];
                    print "`$File' set group to '$data{'group'}'\n" if $argv{'verbose'};
                    if (defined $gid) {
                        if (!$argv{'dry-run'}) {
                            if (! -l $file) { $check = chown($uid, $gid, $file); }
                            else {
                                my $cmd = join(" ", ("chgrp", "-h", escapeshellarg($data{'group'}), escapeshellarg("./$file"), "2>&1"));
                                `$cmd`; $check = ($? == 0);
                            }
                        }
                        else { $check = 1; }
                        warn "warn: `$File' cannot set group to '$data{'group'}'\n" if !$check;
                        last set_group if $check;
                    }
                    else {
                        warn "warn: $data{'group'} is not a valid user group.\n";
                    }
                }
                if ($fields_used{'gid'} && $data{'gid'} ne "") {
                    my $uid = (lstat($file))[4];
                    my $gid = $data{'gid'};
                    print "`$File' set gid to '$gid'\n" if $argv{'verbose'};
                    if (!$argv{'dry-run'}) {
                        if (! -l $file) { $check = chown($uid, $gid, $file); }
                        else {
                            my $cmd = join(" ", ("chgrp", "-h", escapeshellarg($gid), escapeshellarg("./$file"), "2>&1"));
                            `$cmd`; $check = ($? == 0);
                        }
                    }
                    else { $check = 1; }
                    warn "warn: `$File' cannot set gid to '$gid'\n" if !$check;
                }
            }
            if ($fields_used{'mode'} && $data{'mode'} ne "" && ! -l $file) {
                my $mode = oct($data{'mode'}) & 07777;
                print "`$File' set mode to '$data{'mode'}'\n" if $argv{'verbose'};
                $check = !$argv{'dry-run'} ? chmod($mode, $file) : 1;
                warn "warn: `$File' cannot set mode to '$data{'mode'}'\n" if !$check;
            }
            if ($fields_used{'acl'} && $data{'acl'} ne "") {
                print "`$File' set acl to '$data{'acl'}'\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    my $cmd = join(" ", ("setfacl", "-bm", escapeshellarg($data{'acl'}), escapeshellarg("./$file"), "2>&1"));
                    `$cmd`; $check = ($? == 0);
                }
                else { $check = 1; }
                warn "warn: `$File' cannot set acl to '$data{'acl'}'\n" if !$check;
            }
            if ($fields_used{'mtime'} && $data{'mtime'} ne "") {
                my $mtime = gmtime_to_timestamp($data{'mtime'});
                my $atime = (lstat($file))[8];
                print "`$File' set mtime to '$data{'mtime'}'\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    if (! -l $file) { $check = utime($atime, $mtime, $file); }
                    else {
                        my $cmd = join(" ", ("touch", "-hcmd", escapeshellarg($data{'mtime'}), escapeshellarg("./$file"), "2>&1"));
                        `$cmd`; $check = ($? == 0);
                    }
                }
                else { $check = 1; }
                warn "warn: `$File' cannot set mtime to '$data{'mtime'}'\n" if !$check;
            }
            if ($fields_used{'atime'} && $data{'atime'} ne "") {
                my $mtime = (lstat($file))[9];
                my $atime = gmtime_to_timestamp($data{'atime'});
                print "`$File' set atime to '$data{'atime'}'\n" if $argv{'verbose'};
                if (!$argv{'dry-run'}) {
                    if (! -l $file) { $check = utime($atime, $mtime, $file); }
                    else {
                        my $cmd = join(" ", ("touch", "-hcad", escapeshellarg($data{'atime'}), escapeshellarg("./$file"), "2>&1"));
                        `$cmd`; $check = ($? == 0);
                    }
                }
                else { $check = 1; }
                warn "warn: `$File' cannot set atime to '$data{'atime'}'\n" if !$check;
            }
        }
        close(GIT_STORE_META_FILE);
    }
    else {
        die "error: `$git_store_meta_file' is using an unsupported version: $cache_version\n";
    }
}
