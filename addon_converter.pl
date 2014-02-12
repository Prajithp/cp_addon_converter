#!/usr/bin/perl

#Author : Prajith P <prajithpalakkuda@gmail.com>
#web    : http://prajith.in
#Date   : 28/10/2013 
#License: GPL

BEGIN { unshift @INC, '/usr/local/cpanel'; }

use JSON                           ();
use IPC::Open3                     ();
use Cpanel::PublicAPI              ();
use Cpanel::SafeSync               ();
use Cpanel::SimpleSync::CORE       ();
use Cpanel::YAML                   ();
use Cpanel::LoadFile               ();
use Cpanel::FileUtils              ();
use Cpanel::AcctUtils              ();
use Cpanel::Validate::Username     ();
use Cpanel::StringFunc             ();
use Cpanel::FileUtils::Match       ();
use Data::Dumper;
use Getopt::Long;
use Term::ANSIColor qw(:constants);

my $VERSION = '1.3';

my $addon_domain = undef;
my $main_user    = undef;
my $user         = undef;
my $password     = undef;
my $main_domain  = undef;

unless (GetOptions(
       'addon_domain=s'    => \$addon_domain,
       'main_user=s'       => \$main_user,
       'addon_user=s'      => \$user,
       'addon_pass=s'      => \$password,
       'V|version'         => sub { print_version() },
       'h|help'       => sub { usage() },
) or usage()) { udage() };

my $main_dir    = '/home/addon_convert';
my $work_dir    = "/home/addon_convert/cpmove-$user";
$main_domain    = Cpanel::AcctUtils::Domain::getdomain($main_user);

if (defined $addon_domain && defined $main_user && defined $user && defined $password && defined $main_domain) {
    verify_inputs();
    print_header();
    make_dir_tree();
    move_files_from_home();
    copy_domainkey();
    copy_zone_file();
    make_userdata();
    make_userdata_main();
    make_cp_conf();
    make_meta_files();
    make_mysql_priv();
    copy_log_file();
    make_system_files();
    make_dummy_file();
    copy_va_files();
    copy_mailman_files();
    build_tar_archive(
      'user'            => $user,
      'work_dir'        => $work_dir,
      'prifix'          => 'cpmove',
      'basedir'         => $main_dir,
    );
    print_footer();
} 
else {
    usage();
    exit 1;
}



sub get_addon_hash {
  my $sys_user = shift;
  my $returnHash;
  my $hash;
  my $listdomains = liveapi_request('listaddondomains', 'Park', $sys_user);
  foreach my $acct (@{$listdomains->{cpanelresult}->{data}}) {
    $hash = { "domain" => $acct->{domain}, "homedir" => $acct->{dir}};
    $returnHash->{$acct->{domain}} = $hash;
  }
  return $returnHash;
} 


sub read_hash {
    my $theHash = "/root/.accesshash";
    unless ( -f $theHash ) {
    my $pid = IPC::Open3::open3( my $wh, my $rh, my $eh, '/usr/local/cpanel/whostmgr/bin/whostmgr setrhash' );
    waitpid( $pid, 0 );
    }
    open( my $hash_fh, "<", "/root/.accesshash" ) || die "Cannot open access hash: " . $theHash;
    my $accesshash = do { local $/; <$hash_fh>; };
    $accesshash =~ s/\n//g;
    return $accesshash;
}


sub liveapi_request {
  my ($func, $module, $user) = @_;
  my $accesshash = read_hash();
  my $username = 'root';
  my $publicAPI = Cpanel::PublicAPI->new(
            usessl     => 0,
            user       => $username,
            accesshash       => $accesshash
          );
  my $response;
  if (defined $module && defined $func && defined $user){
    $response = $publicAPI->cpanel_api2_request('whostmgr', { 'module' => $module, 'func' =>  $func, user => $user, }, undef, 'json' );
  }
  else {
    $response = $publicAPI->whm_api( $func, undef, 'json' );
  }
  my $json_obj = JSON->new();
  my $json     = $json_obj->allow_nonref->utf8->relaxed->decode( $response );
  return $json;
}


sub read_file_as_hash {
    my ($file) = @_;

    my %ret;

    open( my $fh, '<', $file ) or die("Unable to open $file for reading: $!");

    while ( my $line = readline($fh) ) {
        chomp $line;

        next if $line =~ /^\s*#/;
        next unless $line =~ /^(\S+)=(\S+)$/;

        $ret{$1} = $2;
    }

    close $fh;

    return \%ret;
}

sub build_pkgtree {
    my ($work_dir) = @_;

    my @pkgtree_dirs = qw(
      bandwidth counters cp cron dnszones domainkeys domainkeys/private domainkeys/public fp fp/sites
      httpfiles locale logaholic logs meta mm mma mma/priv mma/pub mms mysql mysql-timestamps
      psql resellerconfig resellerfeatures resellerpackages sslcerts sslkeys ssl suspended suspendinfo userdata
      va vad vf
    );

    if ( !-e $work_dir ) {
        mkdir( $work_dir, 0700 ) or die "Could not create directory $work_dir: $!\n";
    }

    foreach my $dir (@pkgtree_dirs) {
        $dir = "$work_dir/$dir";
        if ( !-e $dir ) {
            mkdir( $dir, 0700 ) or die "Could not create directory $dir: $!\n";
        }
    }
}


sub copy_domainkey {
    print "copying domainkeys...\n";
    my $domainKeydir = '/var/cpanel/domain_keys';
    if ( -e "$domainKeydir/public/$addon_domain" ) {
       Cpanel::SimpleSync::CORE::syncfile( "$domainKeydir/public/$addon_domain", "$work_dir/domainkeys/public/" );
    }
    if ( -e "$domainKeydir/private/$addon_domain" ) { 
       Cpanel::SimpleSync::CORE::syncfile( "$domainKeydir/private/$addon_domain", "$work_dir/domainkeys/private/" );
    }
}


sub copy_zone_file {
    print "copying dnz zone files....\n";
    my $zone_file = "/var/named/$addon_domain" . '.db';
    if (-e "$zone_file") {
       Cpanel::SimpleSync::CORE::syncfile( "$zone_file", "$work_dir/dnszones/");
    }
}


sub make_userdata {
    my $wwwaccts = load_wwwacct();
    my $dump = Cpanel::LoadFile::loadfile("/var/cpanel/userdata/$main_user/$main_domain");
    my $yaml_parse  = Cpanel::YAML::Load("$dump");
    delete $yaml_parse->{include} if defined $yaml_parse->{include};
    ##setting up values###
    $yaml_parse->{ifmodulemodruidc}->{ruidgid}[0]->{value} = "$user $user";
    $yaml_parse->{group} = "$user";
    $yaml_parse->{user}  = "$user";
    $yaml_parse->{owner} = 'root';
    $yaml_parse->{ip}   = $wwwaccts->{ADDR};
    $yaml_parse->{documentroot} = $wwwaccts->{HOMEDIR} . "/$user/public_html";
    $yaml_parse->{serveralias}  = 'www.' . "$addon_domain";
    $yaml_parse->{homedir} = $wwwaccts->{HOMEDIR} . "/$user";
    $yaml_parse->{servername} = $addon_domain;
    $yaml_parse->{serveradmin} = 'webmaster@' . "$addon_domain";
    $yaml_parse->{ifmodulemodsuphpc}->{group} =  $user;
    $yaml_parse->{customlog}[0]->{target} = "/usr/local/apache/domlogs/$addon_domain";
    $yaml_parse->{customlog}[1]->{target} = "/usr/local/apache/domlogs/$addon_domain-bytes_log";
    $yaml_parse->{scriptalias}[0]->{path} = "$wwwaccts->{HOMEDIR}" ."/$user/public_html/cgi-bin";
    $yaml_parse->{scriptalias}[1]->{path} = "$wwwaccts->{HOMEDIR}" ."/$user/public_html/cgi-bin/";
    Cpanel::FileUtils::Write::writefile( "$work_dir/userdata/$addon_domain", Cpanel::YAML::Dump($yaml_parse), 0600 ) or die $!;

}

sub make_userdata_main {
    my $main_userdata = { 'addon_domains' => {}, 'main_domain' => $addon_domain, 'parked_domains' => [], 'sub_domains' => []};
    Cpanel::FileUtils::Write::writefile( "$work_dir/userdata/main", Cpanel::YAML::Dump($main_userdata), 0600 ) or die $!;
}

sub make_cp_conf {
    my $wwwaccts = load_wwwacct();
    my $main_user_cp = read_file_as_hash("/var/cpanel/users/$main_user");
    my $cp_tmplate = {
         'HASDKIM'            => '0',
         'MAXPARK'            => $main_user_cp->{MAXPARK},
         'notify_disk_limit'  => $main_user_cp->{notify_disk_limit},
         'DEMO'               => '0',
         'MAXADDON'           => $main_user_cp->{MAXADDON},
         'USER'               => $user,
         'LEGACY_BACKUP'      => $main_user_cp->{LEGACY_BACKUP},
         'MAX_DEFER_FAIL_PERCENTAGE' => $main_user_cp->{MAX_DEFER_FAIL_PERCENTAGE},
         'HASSPF'             => '0',
         'CONTACTEMAIL'       => $main_user_cp->{CONTACTEMAIL},
         'IP'                 => $wwwaccts->{ADDR},
         'DNS'                => $addon_domain,
         'LOCALE'             => $main_user_cp->{LOCALE},
         'MAXFTP'             => $main_user_cp->{MAXFTP},
         'STARTDATE'          => $main_user_cp->{STARTDATE},
         'MAXSQL'             => $main_user_cp->{MAXSQL},
         'MAXLST'             => $main_user_cp->{MAXLST},
         'notify_email_quota_limit' => $main_user_cp->{notify_email_quota_limit},
         'LANG'               => $main_user_cp->{LANG},
         'FEATURELIST'        => 'default',
         'HASCGI'             => '1',
         'PLAN'               => 'default',
         'MAX_EMAIL_PER_HOUR' => $main_user_cp->{MAX_EMAIL_PER_HOUR},
         'CONTACTEMAIL2'      => $main_user_cp->{CONTACTEMAIL2},
         'BWLIMIT'            => $main_user_cp->{BWLIMIT},
         'MAXPOP'             => $main_user_cp->{MAXPOP},
         'MAXSUB'             => $main_user_cp->{MAXSUB},
         'MTIME'              => $main_user_cp->{MTIME},
         'RS'                 => $main_user_cp->{RS},
         'DBOWNER'            => $user,
         'OWNER'              => 'root',
    };
    my $content;
    foreach my $key (keys %{$cp_tmplate}) {
      $content .= "$key=" . "$cp_tmplate->{$key}" . "\n";
    }
    Cpanel::FileUtils::Write::writefile( "$work_dir/cp/$user", $content, 600) or die $!;
}

sub make_meta_files {
    my $wwwaccts = load_wwwacct();
    my $dbmap_yaml = {MYSQL => {'dbs' => {}, 'dbusers' => {}, 'noprefix' => {}, 'owner' => $user, 'server' => $wwwaccts->{ADDR}} };
    my $dbprefix   = '1';
    my $homedir_paths = "$wwwaccts->{HOMEDIR}" . "/$user";
    my $mailserver = 'dovecot';
    
    Cpanel::FileUtils::Write::writefile( "$work_dir/meta/dbmap.yaml", Cpanel::YAML::Dump($dbmap_yaml), 0600 ) or die $!;
    Cpanel::FileUtils::Write::writefile( "$work_dir/meta/dbprefix", $dbprefix, 0600 ) or die $!;
    Cpanel::FileUtils::Write::writefile( "$work_dir/meta/homedir_paths", $homedir_paths, 0600 ) or die $!;
    Cpanel::FileUtils::Write::writefile( "$work_dir/meta/mailserver", $mailserver, 0600 ) or die $!;
}


sub make_mysql_priv {
    print "creating mysql default privileges\n";
    my $mysql_usage = "GRANT USAGE ON *.* TO " . "'$user'\@'localhost' IDENTIFIED BY " . "'$password';" ;
    my $mysql_grand = "GRANT ALL PRIVILEGES ON " . "`$user\_\%`.* TO " . "'$user'\@'localhost';";
    Cpanel::FileUtils::Write::writefile( "$work_dir/mysql.sql", "$mysql_usage\n$mysql_grand", 0600 ) or die $!;
}

sub copy_log_file {
    print " copying apache domlogs files....\n";
    my @logfiles = ("$addon_domain", "$addon_domain-bytes_log", "ftp.$addon_domain-ftp_log");
    foreach my $logfile (@logfiles) {
      if (-e "/usr/local/apache/domlogs/$logfile") {
        Cpanel::SimpleSync::CORE::syncfile( "/usr/local/apache/domlogs/$logfile", "$work_dir/logs", 0, 0, 1 );
      }
    }
}


sub make_system_files {
    print "Creating system files......\n";
    my $wwwaccts = load_wwwacct();
    my $homedir_paths = $wwwaccts->{HOMEDIR} . "/$user";
    my $shell         = '/bin/bash';
    my $shaddow_hash  = md5_cryptes($password);
    my $pkg_version   = '10';
    my $archive_version = '3';
    if ( open( my $ver_h, '>', "$work_dir/version" ) ) {
      print {$ver_h} "pkgacct version: $pkg_version\n";
      print {$ver_h} "archive version: $archive_version\n";
      close($ver_h);
    }
    Cpanel::FileUtils::Write::writefile( "$work_dir/homedir_paths", "$homedir_paths", 0600 );
    Cpanel::FileUtils::Write::writefile( "$work_dir/shell", $shell, 0600 );
    Cpanel::FileUtils::Write::writefile( "$work_dir/shadow", $shaddow_hash, 0600 );
}

sub make_dummy_file {
    my @files = ("addons", "digestshadow", "nobodyfiles", "pds", "proftpdpasswd", "sds", "sds2", "ssldomain");
    foreach my $file (@files) {
      Cpanel::FileUtils::Write::writefile( "$work_dir/$file", '', 0600);
    }
}

#######we are not using this function at the moment#######
sub get_packages_as_hash {
    my $package_list = liveapi_request('listpkgs');
    my $package_hash;
    my $reutnHash;
    foreach my $pkg (@{$package_list->{package}}) {
      $package_hash = {
          'name'        => $pkg->{name},
          'FEATURELIST' => $pkg->{FEATURELIST},
          'QUOTA'       => $pkg->{QUOTA},
          'MAXSUB'      => $pkg->{MAXSUB},
          'MAXADDON'    => $pkg->{MAXADDON},
          'MAX_DEFER_FAIL_PERCENTAGE' => $pkg->{MAX_DEFER_FAIL_PERCENTAGE},
          'CGI'         => $pkg->{CGI},
          'HASSHELL'    => $pkg->{HASSHELL},
          'DIGESTAUTH'  => $pkg->{DIGESTAUTH},
          'LANG'        => $pkg->{LANG},
          'MAX_EMAIL_PER_HOUR' => $pkg->{MAX_EMAIL_PER_HOUR},
          'MAXFTP'      => $pkg->{MAXFTP},
          'CPMOD'       => $pkg->{CPMOD},
          'name'        => $pkg->{name},
          'MAXLST'      => $pkg->{MAXLST},
          'MAXPARK'     => $pkg->{MAXPARK},
          'BWLIMIT'     => $pkg->{BWLIMIT},
          'FRONTPAGE'   => $pkg->{FRONTPAGE},
          'IP'          => $pkg->{IP},
          'MAXPOP'      => $pkg->{MAXPOP},
          'MAXSQL'      => $pkg->{MAXSQL},
      };
      $reutnHash->{$pkg->{name}} = $package_hash;
   }
   return $reutnHash;
}
#############################

sub move_files_from_home {
    print "copying home_dir and email address files\n";
    my $wwwaccts = load_wwwacct();
    my $user_homedir = $wwwaccts->{HOMEDIR} . "/$main_user";
    my $addon_hash = get_addon_hash($main_user);
    my $addon_domain_homedir = $addon_hash->{$addon_domain}->{homedir};
    my $maildir = "$user_homedir/mail/$addon_domain";
    mkdir("$work_dir/homedir") if !-d "$work_dir/homedir";
    my @dirs = qw(
        etc
        ssl
        ssl/csrs
        ssl/certs
        ssl/keys
        .cpanel
        .cpanel/caches
        .cpanel/caches/filesys
        .cpanel/caches/dynamicui
        .cpanel/datastore
        .cpanel/nvdata
        public_html
        public_html/cgi-bin
        .htpasswds
        public_ftp
        public_ftp/incoming
        tmp
        tmp/analog
        tmp/webalizerftp
        tmp/logaholic
        tmp/awstats
        tmp/cpbandwidth
        tmp/webalizer
        mail
        mail/.Trash
        mail/.Trash/new
        mail/.Trash/cur
        mail/.Trash/tmp
        mail/new
        mail/cur
        mail/tmp
        mail/.Drafts
        mail/.Drafts/new
        mail/.Drafts/cur
        mail/.Drafts/tmp
        mail/.Sent
        mail/.Sent/new
        mail/.Sent/cur
        mail/.Sent/tmp
      );
      foreach my $dir (@dirs) {
        next if -d "$work_dir/homedir/$dir";
        mkdir("$work_dir/homedir/$dir") or die "can't create $dir: $!";
      }
      if ( -d $maildir) {
        my @cmd = ("rsync", '-rlptD', $maildir, "$work_dir/homedir/mail/");
        system("@cmd");
      }
      if ( -d "$user_homedir/etc/$addon_domain") {
        my @cmd = ("rsync", '-rlptD', "$user_homedir/etc/$addon_domain", "$work_dir/homedir/etc/");
        system("@cmd");
      }
      if ( -d "$addon_domain_homedir") {
        my @cmd = ("rsync", '-rltpD', "$addon_domain_homedir/", "$work_dir/homedir/public_html/");
        system(@cmd);
        my @link_dir = ("ln",  '-s', "public_html", "$work_dir/homedir/www");
        system(@link_dir);
      }
}

sub copy_va_files {
    print "Copying virtlal mail files\n";
    my $valiases = "/etc/valiases/$addon_domain";
    my $vfilter  = "/etc/vfilters/$addon_domain";
    my $vdomain  = "/etc/vdomainaliases/$addon_domain";
    if (-e $valiases) {
      Cpanel::SimpleSync::CORE::syncfile( "$valiases", "$work_dir/va/");
      Cpanel::StringFunc::regsrep( $work_dir . '/va/' . $addon_domain, '^\*: ' . $main_user . '[\s\t]*$', '*: ' . $user, 1 );
    }
    if (-e $vfilter) {
      Cpanel::SimpleSync::CORE::syncfile( "$vfilter", "$work_dir/vf/");
    }
    if (-e $vdomain) {
      Cpanel::SimpleSync::CORE::syncfile( "$vdomain", "$work_dir/vad/");
      Cpanel::StringFunc::regsrep( $work_dir . '/vad/' . $addon_domain, '^\*: ' . $main_user . '[\s\t]*$', '*: ' . $user, 1 );
    }
}

sub copy_mailman_files {
    print "Copying mailman files\n";
    my %LISTTARGETS;
    if ( -r '/usr/local/cpanel/3rdparty/mailman/lists' ) {
      $LISTTARGETS{'mm'} = Cpanel::FileUtils::Match::get_matching_files( '/usr/local/cpanel/3rdparty/mailman/lists', "_(?:$addon_domain)" . '$' );
    }
    if ( -r '/usr/local/cpanel/3rdparty/mailman/suspended.lists' ) {
      $LISTTARGETS{'mma'} = Cpanel::FileUtils::Match::get_matching_files( '/usr/local/cpanel/3rdparty/mailman/suspended.lists', "_(?:$addon_domain
      )" . '$' );
    }
    if ( -r '/usr/local/cpanel/3rdparty/mailman/archives/private' ) {
      $LISTTARGETS{'mma/priv'} = Cpanel::FileUtils::Match::get_matching_files( '/usr/local/cpanel/3rdparty/mailman/archives/private', "_(?:$addon_domain)" . '(?:\.mbox)?$' );
    }
    foreach my $target ( keys %LISTTARGETS ) {
      my $file_list = $LISTTARGETS{$target};
      if ( ref $file_list && @$file_list ) {
        foreach my $dir (@$file_list) {
           my @path = split( /\/+/, $dir );
           my $base_file = pop @path;
           mkdir( $work_dir . '/' . $target . '/' . $base_file, 0700 ) if !-e $work_dir . '/' . $target . '/' . $base_file;
           my @cmd = ("rsync", '-rlptD', $dir . '/', $work_dir . '/' . $target . '/' . $base_file);
           system(@cmd);
        }
      }
    }
}

sub md5_cryptes {
    my $password = shift;
    my $encrypted = `echo $password |openssl passwd -1 -stdin`;
    return $encrypted;
}


sub load_wwwacct {
    my $acct_file = '/etc/wwwacct.conf';
    my %ret;
    open( my $fh, '<', $acct_file ) or die("Unable to open $acct_file for reading: $!");
    while ( my $line = readline($fh) ) {
      chomp $line;
      next if $line =~ /^\s*#/;
      next unless $line =~ /^(\S+) (\S+)$/;
      $ret{$1} = $2;
    }
    close $fh;
    return \%ret;
}

sub verify_inputs {
    my $addon_hash = get_addon_hash($main_user);
    my $exist_addon = $addon_hash->{$addon_domain}->{domain};
    
    if (!-f "/var/cpanel/userdata/$main_user/$main_domain") {
      print "Unable to find the main domain of the specified addon_domain\n";
      exit 1;
    } 
    if (not $exist_addon) {
      print "The addon_domain not exist\n";
      exit 1;
    }
    if (not $user || not $password) {
      print "Please specify the new username and password\n";
      exit 1;
    }
    if ( Cpanel::AcctUtils::accountexists($user) ) {
      print "Sorry, the new user $user already exists on this system, Please choose another username\n";
      exit(1);
    }
    if ( Cpanel::Validate::Username::group_exists($user) ) {
      print "Sorry, the group $user already exists on this system. Please choose another username\n";
      exit(1);
    }
    return 1;
}

sub make_dir_tree {
    print "creating $work_dir.....\n";
    system("rm -rf $work_dir") if -d $work_dir;
    system("mkdir -p $work_dir"); 
    if ( -d $work_dir) {
      build_pkgtree($work_dir);
    } else {
      die "unable to create work_dir $work_dir";
    }
}

sub build_tar_archive {
  my (%args) = @_;
  my $work_dirs = $args{work_dir};
  my $new_user  = $args{user};
  my $prifix    = $args{prifix};
  my $base_dir  = $args{basedir};
  my @path      = split( /\/+/, $work_dirs );
  my $base_file = pop @path;
  my $archive_file = $prifix . '-' . $user . '.tar.gz';
  chdir($base_dir) or die "Cannot change work_dir to $base_dir: $!";
  
  my @tar_cmd = ('tar', '-zcf', $archive_file, $base_file); 
  print "\ncreating tar archive, this may take a while\n\n";
  system(@tar_cmd);
}

sub usage {
    print "Usage:\n";
    print "$0 --addon_domain=<addon_domain_name> --main_user=<main cpanel username>  --addon_user=<new domain username> --addon_pass=<new domain password>\n\n";
    print "requird options\n";
    print "--addon_domain: specify the addon domain name which you want to conver\n";
    print "--main_user   : specify the usename of the addon domain\n";
    print "--addon_user  : specify the new account username\n";
    print "--addon_pass  : specify the password for new account\n\n";
    print "optional\n";
    print "-V   : print script version\n";
    print "-h   : print this help message and exit\n";
    exit 0; 
}

sub print_version {
    print "$VERSION\n";
    exit 0;
}

sub print_header {
  print BOLD WHITE "\n\n\t\t\t[ cPanel Addon converter V $VERSION ]" .  RESET . "\n\n\n";
  print qq{
################################################################################################
cPanel Addon converter comes with ABSOLUTELY NO WARRANTY. This is free software, and you are
  welcome to redistribute it under the terms of the GNU General Public License.
  See the LICENSE file for details about using this software.
Copyright 2013-2014 - Prajith P, http://www.prajith.in/
#################################################################################################
  };
  print "\nThe script will copy almost all files related to the addon domain except mysql databases and privileges\n";
  print "Please copy the mysql databases and database users manually and restore it once complete\n";
  print "Once you have restored the cpmove archive, please change the domain package/owner from WHM\n\n";
  
  print BOLD WHITE "\n\n[+] Initializing Script" . RESET . "\n\n\n";
  print BOLD WHITE "[ Press [ANY KEY] to continue, or [CTRL]+C to stop ]" . RESET "\n\n";
  <STDIN>;
}


sub print_footer {
    print "\n\n\ncpmove archive has been created in $main_dir, you can restore this arcive using /scripts/restorepkg command\n";
}
