#!/usr/bin/env perl 

# Released under the GNU General Public License v2
# Jörg Kost joerg.kost@gmx.com

use MIME::Base64;
use JSON;
use REST::Client;
use Data::Dumper;
use Modern::Perl;
use Proc::SafeExec;
use IO::Socket::INET;

BEGIN { $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0 }
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

if(! $ENV{ONAPP_USER} || ! $ENV{ONAPP_TOKEN} || ! $ENV{ONAPP_URL}) {
    say "Please set ONAPP_USER, ONAPP_TOKEN and ONAPP_URL in your environment";
    exit;
}

if ( $#ARGV < 6 ) {
    say
"Need arguments: #manifest #onapp_template #hostname #cpu #cpu_sockets #cpu_threads #memory #primary_disk_size #hypervisor_id (#initialpassword)";
    exit;
}

my (
    $manifest, $onapp_template, $hostname,
    $cpu,      $cpu_sockets,    $cpu_threads,
    $memory,   $disk_size,      $hypervisor_id, $initialpassword
) = @ARGV;

my %manifest = ( 'RexfileJob' => 'Deploy:Tomcat' );
my $user = $ENV{ONAPP_USER};
my $pass = $ENV{ONAPP_TOKEN};
my $rest = REST::Client->new( { host => $ENV{ONAPP_URL} } );
my $headers = {
    Authorization  => 'Basic ' . encode_base64( $user . ':' . $pass ),
    'Content-type' => 'application/json'
};

$rest->getUseragent()->ssl_opts( SSL_verify_mode => 0 );

if (!$initialpassword) { $initialpassword = generate_random_string(); }

my %vm_definition = (
    virtual_machine => {
        template_id                      => $onapp_template,
        label                            => $hostname,
        hostname                         => $hostname,
        memory                           => $memory,
        cpus                             => $cpu,
        primary_disk_size                => $disk_size,
        hypervisor_id                    => $hypervisor_id,
        cpu_shares                       => 50,
        cpu_sockets                      => $cpu_sockets,
        cpu_threads                      => $cpu_threads,
        initial_root_password            => $initialpassword,
        required_virtual_machine_build   => 1,
        required_virtual_machine_startup => 1,
        required_ip_address_assignment   => 1
    }
);

my $vm = create_vm( encode_json( \%vm_definition ) );
if (!$vm) { say "VM not ready, exiting?"; exit; }


say "$vm->{virtual_machine}{identifier} will be launched soon";
say
      "ssh root\@$vm->{virtual_machine}{ip_addresses}[0]{ip_address}{address}";
say "password: $initialpassword";

# Deploy things with rex...
# or some other cfm-tool
# what about user-data and cloudboot?
# call evil system for apt-get 

if ($ENV{ONAPP_SILENT_UPGRADE}) {
    say "Waiting for boot, then running manifest";
    wait_vm_boot($vm);
    say "VM ready, running sys-update";
    system("ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root\@$vm->{virtual_machine}{ip_addresses}[0]{ip_address}{address} 'apt-get -qq update && apt-get -qqy upgrade' ");
} else {
    say "ONAPP_SILENT_UPGRADE not set, will not execute sys-update";
}


sub create_vm {
    my $vm_json = shift;
    $rest->POST( '/virtual_machines.json', $vm_json, $headers );
    my $respone = $rest->responseContent();

    my $r = decode_json($respone);
    if (   $r->{virtual_machine}{remote_access_password}
        && $r->{virtual_machine}{id}
        && $r->{virtual_machine}{ip_addresses}[0]{ip_address}{address} ) {
        return $r;
    }
    return undef;
}

sub generate_random_string {
    my @chars = ( 'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_' );
    my $random_string;
    foreach ( 1 .. 12 ) {
        $random_string .= $chars[ rand @chars ];
    }
    return $random_string;
}

sub wait_vm_boot {    
    # Our creation time loop
    my $maxwait  = 1000;
    my $waitloop = 10;
    my $waited   = 0;
    my $r = shift;

    if (   $r->{virtual_machine}{remote_access_password}
        && $r->{virtual_machine}{id}
        && $r->{virtual_machine}{ip_addresses}[0]{ip_address}{address} )
    {
        while (1) {
            my $sock = IO::Socket::INET->new(
                PeerAddr =>
                  $r->{virtual_machine}{ip_addresses}[0]{ip_address}{address},
                PeerPort => '22',
                Proto    => 'tcp'
            );
            my $data = <$sock>;
            if ( $data && $data =~ /SSH/ ) {
                return $r;
            }
            else {
                sleep($waitloop);
                $waited += $waitloop;
                if ( $waited > $maxwait ) {
                    say "Waited enough! Breaking out";
                    last;
                }
            }
        }
    }  
}
