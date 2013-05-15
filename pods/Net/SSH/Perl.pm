# $Id: Perl.pm,v 1.126 2009/02/02 01:18:27 turnstep Exp $

package Net::SSH::Perl;
use strict;

use Net::SSH::Perl::Packet;
use Net::SSH::Perl::Buffer;
use Net::SSH::Perl::Config;
use Net::SSH::Perl::Constants qw( :protocol :compat :hosts );
use Net::SSH::Perl::Cipher;
use Net::SSH::Perl::Util qw( :hosts _read_yes_or_no );

use vars qw( $VERSION $CONFIG $HOSTNAME );
$CONFIG = {};

use Socket;
use IO::Socket;
use Fcntl;
use Symbol;
use Carp qw( croak );
use Sys::Hostname;
eval {
    $HOSTNAME = hostname();
};

$VERSION = '1.35';

sub VERSION { $VERSION }

sub new {
    my $class = shift;
    my $host = shift;
    croak "usage: ", __PACKAGE__, "->new(\$host)"
        unless defined $host;
    my $ssh = bless { host => $host }, $class;
    my %p = @_;
    $ssh->{_test} = delete $p{_test};
    $ssh->_init(%p);
    $ssh->_connect unless $ssh->{_test};
    $ssh;
}

sub protocol { $_[0]->{use_protocol} }

sub set_protocol {
    my $ssh = shift;
    my $proto = shift;
    $ssh->{use_protocol} = $proto;
    my $proto_class = join '::', __PACKAGE__,
        ($proto == PROTOCOL_SSH2 ? "SSH2" : "SSH1");
    (my $lib = $proto_class . ".pm") =~ s!::!/!g;
    require $lib;
    bless $ssh, $proto_class;
    $ssh->debug($proto_class->version_string);
    $ssh->_proto_init;
}

use vars qw( @COMPAT );
@COMPAT = (
  [  '^OpenSSH[-_]2\.[012]' => SSH_COMPAT_OLD_SESSIONID,   ],
  [  'MindTerm'             => 0,                          ],
  [  '^2\.1\.0 '            => SSH_COMPAT_BUG_SIGBLOB |
                               SSH_COMPAT_BUG_HMAC |
                               SSH_COMPAT_OLD_SESSIONID,   ],
  [  '^2\.0\.'              => SSH_COMPAT_BUG_SIGBLOB |
                               SSH_COMPAT_BUG_HMAC |
                               SSH_COMPAT_OLD_SESSIONID |
                               SSH_COMPAT_BUG_PUBKEYAUTH |
                               SSH_COMPAT_BUG_X11FWD,      ],
  [  '^2\.[23]\.0 '         => SSH_COMPAT_BUG_HMAC,        ],
  [  '^2\.[2-9]\.'          => 0,                          ],
  [  '^2\.4$'               => SSH_COMPAT_OLD_SESSIONID,   ],
  [  '^3\.0 SecureCRT'      => SSH_COMPAT_OLD_SESSIONID,   ],
  [  '^1\.7 SecureFX'       => SSH_COMPAT_OLD_SESSIONID,   ],
  [  '^2\.'                 => SSH_COMPAT_BUG_HMAC,        ],
);

sub _compat_init {
    my $ssh = shift;
    my($version) = @_;
    $ssh->{datafellows} = 0;
    for my $rec (@COMPAT) {
        my($re, $mask) = @$rec[0, 1];
        if ($version =~ /$re/) {
            $ssh->debug("Compat match: '$version' matches pattern '$re'.");
            $ssh->{datafellows} = $mask;
            return;
        }
    }
    $ssh->debug("No compat match: $version.");
}

sub version_string { }

sub client_version_string { $_[0]->{client_version_string} }
sub server_version_string { $_[0]->{server_version_string} }

sub _current_user {
    my $user;
    eval { $user = scalar getpwuid $> };
    return $user;
}

sub _init {
    my $ssh = shift;

    my %arg = @_;
    my $user_config = delete $arg{user_config} || "$ENV{HOME}/.ssh/config";
    my $sys_config  = delete $arg{sys_config}  || "/etc/ssh_config";

    my $directives = delete $arg{options} || [];

    if (my $proto = delete $arg{protocol}) {
        push @$directives, "Protocol $proto";
    }

    my $cfg = Net::SSH::Perl::Config->new($ssh->{host}, %arg);
    $ssh->{config} = $cfg;

    # Merge config-format directives given through "options"
    # (just like -o option to ssh command line). Do this before
    # reading config files so we override files.
    for my $d (@$directives) {
        $cfg->merge_directive($d);
    }

    for my $f (($user_config, $sys_config)) {
        $ssh->debug("Reading configuration data $f");
        $cfg->read_config($f);
    }

    if (my $real_host = $ssh->{config}->get('hostname')) {
        $ssh->{host} = $real_host;
    }

    my $user = _current_user();
    if ($user && $user eq "root" &&
      !defined $ssh->{config}->get('privileged')) {
        $ssh->{config}->set('privileged', 1);
    }

    unless ($ssh->{config}->get('protocol')) {
        $ssh->{config}->set('protocol',
            PROTOCOL_SSH1 | PROTOCOL_SSH2 | PROTOCOL_SSH1_PREFERRED);
    }

    unless (defined $ssh->{config}->get('password_prompt_login')) {
        $ssh->{config}->set('password_prompt_login', 1);
    }
    unless (defined $ssh->{config}->get('password_prompt_host')) {
        $ssh->{config}->set('password_prompt_host', 1);
    }
    unless (defined $ssh->{config}->get('number_of_password_prompts')) {
        $ssh->{config}->set('number_of_password_prompts', 3);
    }
}

sub _proto_init { }

sub register_handler { }

sub config { $_[0]->{config} }

sub configure {
    my $class = shift;
    $CONFIG = { @_ };
}

sub ssh {
    my($host, @cmd) = @_;
    my($user);
    ($host, $user) = $host =~ m!(.+)@(.+)! ?
       ($2, $1) : ($host, _current_user());
    my $ssh = __PACKAGE__->new($host, %$CONFIG);
    $ssh->login($user);
    my($out, $err, $exit) = $ssh->cmd(join ' ', @cmd);
    print $out;
    print STDERR $err if $err;
}

sub issh {
    my($host, @cmd) = @_;
    print join(' ', @cmd), "\n";
    print "Proceed: [y/N]:";
    my $x = scalar(<STDIN>);
    if ($x =~ /^y/i) {
        $CONFIG->{interactive} = 1;
        ssh($host, @cmd);
    }
}

sub _connect {
    my $ssh = shift;
    my $sock = $ssh->_create_socket;

    my $raddr = inet_aton($ssh->{host});
    croak "Net::SSH: Bad host name: $ssh->{host}"
        unless defined $raddr;
    my $rport = $ssh->{config}->get('port') || 'ssh';
    if ($rport =~ /\D/) {
        my @serv = getservbyname(my $serv = $rport, 'tcp');
        $rport = $serv[2] || 22;
    }
    $ssh->debug("Connecting to $ssh->{host}, port $rport.");
    connect($sock, sockaddr_in($rport, $raddr))
        or die "Can't connect to $ssh->{host}, port $rport: $!";

    select((select($sock), $|=1)[0]);

    $ssh->{session}{sock} = $sock;
    $ssh->_exchange_identification;

    defined($sock->blocking(0))
        or die "Can't set socket non-blocking: $!";

    $ssh->debug("Connection established.");
}

sub _create_socket {
    my $ssh = shift;
    my $sock = gensym;

	my ($p,$end,$delta) = (0,1,1); # normally we use whatever port we can get
   	   ($p,$end,$delta) = (1023,512,-1) if $ssh->{config}->get('privileged');

	# allow an explicit bind address
    my $addr = $ssh->{config}->get('bind_address');
	$addr = inet_aton($addr) if $addr;
	($p,$end,$delta) = (10000,65535,1) if $addr and not $p;
	$addr ||= INADDR_ANY;

    for(; $p != $end; $p += $delta) {
        socket($sock, AF_INET, SOCK_STREAM, getprotobyname('tcp') || 0) ||
            croak "Net::SSH: Can't create socket: $!";
        last if not $p or bind($sock, sockaddr_in($p,$addr));
        if ($! =~ /Address already in use/i) {
            close($sock) or warn qq{Could not close socket: $!\n};
            next;
        }
        croak "Net::SSH: Can't bind socket to port $p: $!";
    }
	if($p) {
		$ssh->debug("Allocated local port $p.");
		$ssh->{config}->set('localport', $p);
	}

    $sock;
}

sub _disconnect { }

sub fatal_disconnect {
    my $ssh = shift;
    $ssh->_disconnect(@_);
    croak @_;
}

sub sock { $_[0]->{session}{sock} }

sub _exchange_identification {
    my $ssh = shift;
    my $sock = $ssh->{session}{sock};
    my $remote_id = <$sock>;
    ($ssh->{server_version_string} = $remote_id) =~ s/\cM?\n$//;
    my($remote_major, $remote_minor, $remote_version) = $remote_id =~
        /^SSH-(\d+)\.(\d+)-([^\n]+)\n$/;
    $ssh->debug("Remote protocol version $remote_major.$remote_minor, remote software version $remote_version");

    my $proto = $ssh->config->get('protocol');
    my($mismatch, $set_proto);
    if ($remote_major == 1) {
        if ($remote_minor == 99 && $proto & PROTOCOL_SSH2 &&
            !($proto & PROTOCOL_SSH1_PREFERRED)) {
            $set_proto = PROTOCOL_SSH2;
        }
        elsif (!($proto & PROTOCOL_SSH1)) {
            $mismatch = 1;
        }
        else {
            $set_proto = PROTOCOL_SSH1;
        }
    }
    elsif ($remote_major == 2) {
        if ($proto & PROTOCOL_SSH2) {
            $set_proto = PROTOCOL_SSH2;
        }
    }
    if ($mismatch) {
        croak sprintf "Protocol major versions differ: %d vs. %d",
            ($proto & PROTOCOL_SSH2) ? PROTOCOL_MAJOR_2 :
            PROTOCOL_MAJOR_1, $remote_major;
    }
    my $compat20 = $set_proto == PROTOCOL_SSH2;
    my $buf = sprintf "SSH-%d.%d-%s\n",
        $compat20 ? PROTOCOL_MAJOR_2 : PROTOCOL_MAJOR_1,
        $compat20 ? PROTOCOL_MINOR_2 : PROTOCOL_MINOR_1,
        $VERSION;
    $ssh->{client_version_string} = substr $buf, 0, -1;
    print $sock $buf;

    $ssh->set_protocol($set_proto);
    $ssh->_compat_init($remote_version);
}

sub debug {
    my $ssh = shift;
    if ($ssh->{config}->get('debug')) {
        printf STDERR "%s@_\n", $HOSTNAME ? "$HOSTNAME: " : '';
    }
}

sub login {
    my $ssh = shift;
    my($user, $pass) = @_;
    if (!defined $ssh->{config}->get('user')) {
        $ssh->{config}->set('user',
            defined $user ? $user : _current_user());
    }
    if (!defined $pass && exists $CONFIG->{ssh_password}) {
        $pass = $CONFIG->{ssh_password};
    }
    $ssh->{config}->set('pass', $pass);
}

sub _login { }

sub cmd { }
sub shell { }

sub incoming_data {
    my $ssh = shift;
    if (!exists $ssh->{session}{incoming_data}) {
        $ssh->{session}{incoming_data} = Net::SSH::Perl::Buffer->new( MP => $ssh->protocol == PROTOCOL_SSH2 ? 'SSH2' : 'SSH1' );
    }
    $ssh->{session}{incoming_data};
}

sub session_id {
    my $ssh = shift;
    $ssh->{session}{id} = shift if @_ and not defined $ssh->{session}{id};
    $ssh->{session}{id};
}

sub packet_start { Net::SSH::Perl::Packet->new($_[0], type => $_[1]) }

sub check_host_key {
    my $ssh = shift;
    my($key, $host, $u_hostfile, $s_hostfile) = @_;
    $host ||= $ssh->{host};
    $u_hostfile ||= $ssh->{config}->get('user_known_hosts');
    $s_hostfile ||= $ssh->{config}->get('global_known_hosts');

    my $status = _check_host_in_hostfile($host, $u_hostfile, $key);
    unless (defined $status && $status == HOST_OK) {
        $status = _check_host_in_hostfile($host, $s_hostfile, $key);
    }

    if ($status == HOST_OK) {
        $ssh->debug("Host '$host' is known and matches the host key.");
    }
    elsif ($status == HOST_NEW) {
        if ($ssh->{config}->get('interactive')) {
            my $prompt =
qq(The authenticity of host '$host' can't be established.
Key fingerprint is @{[ $key->fingerprint ]}.
Are you sure you want to continue connecting (yes/no)?);
            unless (_read_yes_or_no($prompt, "yes")) {
                croak "Aborted by user!";
            }
        }
        $ssh->debug("Permanently added '$host' to the list of known hosts.");
        _add_host_to_hostfile($host, $u_hostfile, $key);
    }
    else {
        croak "Host key for '$host' has changed!";
    }
}

1;
__END__

=head1 NAME

Net::SSH::Perl - Perl client Interface to SSH

=head1 SYNOPSIS

    use Net::SSH::Perl;
    my $ssh = Net::SSH::Perl->new($host);
    $ssh->login($user, $pass);
    my($stdout, $stderr, $exit) = $ssh->cmd($cmd);

=head1 DESCRIPTION

这个 <Net::SSH::Perl>  是一个 Perl 模块实现的 SSH 客户端(Secure Shell). 它与 SSH-1 和 SSH-2 协议都是兼容的.

这个 <Net::SSH::Perl> 可以让您可以简单，安全地远程机器上执行命令，并接收远程命令的退出状态， STDOUT，STDERR。

它原生包含并支持服务器上的支持各种认证的方式(密码认证 , RSA 认证，等等)。并完全实现了 SSH 协议上的 I/O buffering, packet transport 和用户认证层，使用了外部的 Perl 模块(Crypt:: 系列)来处理网络上全部的数据收发的加密。并且这个还可以读取现有的 SSH 的配置文件  (F</etc/ssh_config>, etc.), 读取 RSA 的身份文件， DSA 的身份文件，known hosts 文件之类.

这个使用 I<Net::SSH::Perl> 的优点，比起包一个 ssh 客户端成一个新的进程开销小多了，你不需要单独的进程来连接到 sshd 。这样可以少一些创建进程所需要的时间和内存。有时这是相当有用的，象我们在一个长期运行的 Perl 环境中，如 mod_perl 之类。fork 一个新的进程和内存资源的消耗是非常大的。

这个也很大程度上简单了密码认证的过程，如果你包一个现成的 I<ssh> 客户端的子进程时，你需要使用 I<Expect> 来控制客户端，并还要通过这个来传送密码过去。 I<Net::SSH::Perl> 有原生的认证支持。因些使用这个模块不会有任何麻烦与任何外部的进程通信。

兼容完整的 SSH2 protocol   ( 在完成  I<Net::SSH::Perl>  的 1.0 的时候支持 ),也完全兼容官方的 SSH 实现. 如果你发现这个 I<Net::SSH::Perl> 和 SSH2 的实现有什么不兼容，请你告诉我(邮件地址是 I<AUTHOR & COPYRIGHTS>); 事实上，一些 SSH2 的实现都有些细微的差别。

3DES (C<3des-cbc>), Blowfish (C<blowfish-cbc>), 和 RC4 (C<arcfour>) 是目前 SSH2 所支持的加密和 C<hmac-sha1> 或 C<hmac-md5> 的算法进行完整性检查。压缩，如果需要，它是有限制只能 Zlib 。所支持的服务器主机密钥算法是  C<ssh-dss> (默认) 和  C<ssh-rsa> ( 需要 I<Crypt::RSA>); SSH2 所支持的公钥认证算法是相同的。

如果你想了解 SFTP support, 你可以看看 I<Net::SFTP>, 这提供了全功能的 Perl 实现的 SFTP 。 SFTP 只能在 SSH2 协议上使用.

=head1 基本的使用

使用 I<Net::SSH::Perl> 是非常简单的.

=head2 Net::SSH::Perl->new($host, %params)

设置一个新的连接，调用  I<new> 的方法。提供一个连接用的 I<$host> 会返回一个 I<Net::SSH::Perl> 的对象。

这个 I<new> 中的 I<%params> 可以接受下面的命名参数:

=over 4

=item * protocol

您希望使用的协议的连接：应该是用C<2>，<1>，<'1，2'>或C<'2，1'>。前两个写法很简单，"协议"（SSH-2 或 SSH-1）分别只能使用其中一个版本。后面的两个指定任何协议可以使用，但前面的优于后面的协议（逗号分隔的列表中）。

出于这个原因，它是"安全"使用后面的两个协议规范，因为他们保证，无论哪种方式，你都可以连接，如果你的服务器不支持的第一个列出的的协议，第二个列出的将被使用。 （想必你的服务器将支持至少两个协议之一。:)

默认是使用 C<'1,2'>, 因为为了向 OpenSSH 所兼容; 这意味着服务器支持 SSH-1 的话客户端会使用 SSH-1。当然，你还是可以覆盖  user/global 的配置文件，通过这个参数来修改.

=item * cipher

指定你连接时所使用的加密的名字。需
Specifies the name of the encryption cipher that you wish to use for this connection. This must be one of the supported ciphers; specifying an unsupported cipher will give you an error when you enter algorithm negotiation (in either SSH-1 or SSH-2).

In SSH-1, the supported cipher names are I<IDEA>, I<DES>, I<DES3>,
and I<Blowfish>; in SSH-2, the supported ciphers are I<arcfour>,
I<blowfish-cbc>, and I<3des-cbc>.

The default SSH-1 cipher is I<IDEA>; the default SSH-2 cipher is
I<3des-cbc>.

=item * ciphers

Like I<cipher>, this is a method of setting the cipher you wish to
use for a particular SSH connection; but this corresponds to the
I<Ciphers> configuration option, where I<cipher> corresponds to
I<Cipher>. This also applies only in SSH-2.

This should be a comma-separated list of SSH-2 cipher names; the list
of cipher names is listed above in I<cipher>.

This defaults to I<3des-cbc,blowfish-cbc,arcfour>.

=item * port

The port of the I<sshd> daemon to which you wish to connect;
if not specified, this is assumed to be the default I<ssh>
port.

=item * debug

Set to a true value if you want debugging messages printed
out while the connection is being opened. These can be helpful
in trying to determine connection problems, etc. The messages
are similar (and in some cases exact) to those written out by
the I<ssh> client when you use the I<-v> option.

Defaults to false.

=item * interactive

Set to a true value if you're using I<Net::SSH::Perl> interactively.
This is used in determining whether or not to display password
prompts, for example. It's basically the inverse of the
I<BatchMode> parameter in ssh configuration.

Defaults to false.

=item * privileged

如果您想要绑定到本地特权端口( 0-1024 )，需要设置为 true 值。如果您计划使用 Rhosts RSA 的身份验证，你会需要这个，因为远程服务器要求客户端在特权端口上连接。当然，要将绑定到一个特权端口你会需要 root 权限。

如果您没有提供此参数, 但 <Net::SSH::Perl> 检测您运行的用户是 root，这将自动设置为 true。否则，它默认为 false。

=item * identity_files

A list of RSA/DSA identity files to be used in RSA/DSA authentication.
The value of this argument should be a reference to an array of
strings, each string identifying the location of an identity
file. Each identity file will be tested against the server until
the client finds one that authenticates successfully.

If you don't provide this, RSA authentication defaults to using
F<$ENV{HOME}/.ssh/identity>, and DSA authentication defaults to
F<$ENV{HOME}/.ssh/id_dsa>.

=item * compression

If set to a true value, compression is turned on for the session
(assuming that the server supports it).

Compression is off by default.

Note that compression requires that you have the I<Compress::Zlib>
module installed on your system. If the module can't be loaded
successfully, compression is disabled; you'll receive a warning
stating as much if you having debugging on (I<debug> set to 1),
and you try to turn on compression.

=item * compression_level

Specifies the compression level to use if compression is enabled
(note that you must provide both the I<compression> and
I<compression_level> arguments to set the level; providing only
this argument will not turn on encryption).

This setting is only applicable to SSH-1; the compression level for
SSH-2 Zlib compression is always set to 6.

The default value is 6.

=item * use_pty

如果您想在远程计算机上请求伪 tty, 需要将此值设置为 1. 这唯一有用的是如果你设定一个 shell 连接 （请参阅下文 I<shell> 的方法),除非您显式地拒绝 Pty （通过设置 I<use_pty> 为 0）. 不然这都会自动设置为 1。换句话说，你可能不会需要修改它。

如果你启动了一个 shell 会默认值为 1, 否则为 0;

=item * options

用于指定的配置设置附加选项;用于指定构造函数的参数没有单独的选项来指定的东西。类似于 I<ssh> 程序中的 B<-o> 命令。

如果使用，你需要指定一个列表的引用值。例如：

    my $ssh = Net::SSH::Perl->new("host", options => [
        "BatchMode yes", "RhostsAuthentication no" ]);

=back

=head2 $ssh->login([ $user [, $password [, $suppress_shell ] ] ])

Sets the username and password to be used when authenticating
with the I<sshd> daemon. The username I<$user> is required for
all authentication protocols (to identify yourself to the
remote server), but if you don't supply it the username of the
user executing the program is used.

The password I<$password> is needed only for password
authentication (it's not used for passphrases on encrypted
RSA/DSA identity files, though perhaps it should be). And if you're
running in an interactive session and you've not provided a
password, you'll be prompted for one.

默认情况下，Net::SSH::Perl 会在 shell 上打开一个通道。这通常是你想要的。然而，如果你是通过 SSH 隧道上跑另一种协议，你可能会想要来防止这种行为。传递 true 值在 I<$suppress_shell>将防止shell的通道被打开（SSH2 only）。

=head2 ($out, $err, $exit) = $ssh->cmd($cmd, [ $stdin ])

Runs the command I<$cmd> on the remote server and returns
the I<stdout>, I<stderr>, and exit status of that
command.

If I<$stdin> is provided, it's supplied to the remote command
I<$cmd> on standard input.

NOTE: the SSH-1 protocol does not support running multiple commands
per connection, unless those commands are chained together so that
the remote shell can evaluate them. Because of this, a new socket
connection is created each time you call I<cmd>, and disposed of
afterwards. In other words, this code:

    my $ssh = Net::SSH::Perl->new("host1");
    $ssh->login("user1", "pass1");

    $ssh->cmd("foo");
    $ssh->cmd("bar");

will actually connect to the I<sshd> on the first invocation of
I<cmd>, then disconnect; then connect again on the second
invocation of I<cmd>, then disconnect again.

Note that this does I<not> apply to the SSH-2 protocol. SSH-2 fully
supports running more than one command over the same connection.

=head2 $ssh->shell

在远程机器上打开一个可以交互的 SHELL 并给这个连接到你的 STDIN .当你使用伪 tty(pseudo tty) 是这个非常有用，不然你得不到命令行提示符，这样看起来才会很象 shell。所以出于这个原因的考虑，我们默认都要求远程的计算提供 pty。除非你明确的拒绝.

这唯一有用的地方是用于交互式程序时。

此外，你可能会调用此方法之前，要设置你的终端原始输入。这让 I<Net::SSH::Perl> 来处理每一个字符，当你输入时并将其发送到远程机器上。

如果你想这样，你可以在你的程序中使用 I<Term::ReadKey>:

    use Term::ReadKey;
    ReadMode('raw');
    $ssh->shell;
    ReadMode('restore');

事实上，你可能会想要设置 C<restore> 的行在 I<END> 块中，在你的程序退出之前达到该行来恢复。

如果你需要一个例子，看看在 F<eg/pssh> 的，它使用几乎这个代码来实现 SSH shell。

=head2 $ssh->register_handler($packet_type, $subref [, @args ])

在客户端循环中注册一个匿名子程序处理 I<$subref> 处理数据包类型 I<$packet_type>.

当类型为 I<$packet_type> 的数据包到达时，调用子程序，附了标准的参数(见下文)，如果指定了还会接收一些 I<@args> 的额外的参数。

当下列事件后进入 client loop 循环，客户端发送一个命令到远程服务器和任何标准输入数据发送后; 它会读取服务器的数据包象 (STDOUT 包和 STDERR 的包之类),直接到服务器发送远程的 exit 命令。这时 client 退出 loop 并从服务器断开。

当你调用 I<cmd> 的方法时，client loop 默认是简单的粘到 STDOUT 的包到一个标量上并返回 caller 的值，象一些 STDERR 的包和进程的退出状态。 (See the docs for I<cmd>).

所以使用这个接口，你可以重写这个默认的行为来替换进程自己发送给客户端的数据。你这时需要调用 I<register_handler> 的方法和设置当这人特定的时间发送这个时怎么样回调。

I<register_handler> 的方法在 I<Net::SSH::Perl> 的 SSH-1 和  SSH-2  的实现是有区别的, 这是因为 ( SSH-2 是通过通道机制在所有的客户端和服务器上通信的，所以有着不同的方式来处理输入的数据包)。

=over 4

=item * SSH-1 Protocol

In the SSH-1 protocol, you should call I<register_handler> with two
arguments: a packet type I<$packet_type> and a subroutine reference
I<$subref>. Your subroutine will receive as arguments the
I<Net::SSH::Perl::SSH1> object (with an open connection to the
ssh3), and a I<Net::SSH::Perl::Packet> object, which represents the
packet read from the server. It will also receive any additional
arguments I<@args> that you pass to I<register_handler>; this can
be used to give your callback functions access to some of your
otherwise private variables, if desired. I<$packet_type> should be
an integer constant; you can import the list of constants into your
namespace by explicitly loading the I<Net::SSH::Perl::Constants>
module:

    use Net::SSH::Perl::Constants qw( :msg );

This will load all of the I<MSG> constants into your namespace
so that you can use them when registering the handler. To do
that, use this method. For example:

    $ssh->register_handler(SSH_SMSG_STDOUT_DATA, sub {
        my($ssh, $packet) = @_;
        print "I received this: ", $packet->get_str;
    });

To learn about the methods that you can call on the packet object,
take a look at the I<Net::SSH::Perl::Packet> docs, as well as the
I<Net::SSH::Perl::Buffer> docs (the I<get_*> and I<put_*> methods).

Obviously, writing these handlers requires some knowledge of the
contents of each packet. For that, read through the SSH RFC, which
explains each packet type in detail. There's a I<get_*> method for
each datatype that you may need to read from a packet.

Take a look at F<eg/remoteinteract.pl> for an example of interacting
with a remote command through the use of I<register_handler>.

=item * SSH-2 Protocol

在 SSH-2 的协议中，你调用 I<register_handler> 时有二个参数： 一个字符串用来标识你要创建的处理程序的类型和一个子函数的引用。这个中的字符串是指  C<stdout> or C<stderr>;任何其它的东西会被忽略。 C<stdout> 是指你想处理的服务器所发过来的 STDOUT 的数据。 C<stderr> 也一样是服务器发过来的 STDERR 数据.

你的子函数能得到二个参数: 一个 I<Net::SSH::Perl::Channel> 的对象表示发送的数据所打开的通道和一个 I<Net::SSH::Perl::Buffer> 的对象包含从服务器读取数据。

除了这二个参数，回调会传送一些其它的 I<@args> 传过来给 I<register_handler> 的参数。这可以用于给你的回调做私有数据。

这举例来说明 SSH-1 和 SSH-2 实际上的不同。 首先的不同在于如上服务器和客户端之间所有通信都是通过通道。这是建立主要客户端和服务器之间的连接。在相同的连接多个信道被复用。第二个区别，在 SSH-1 中你处理的进来的是实际的数据; 在 SSH-2 这些数据库包都处理过了，然后存在缓冲区中，你需要的是处理这些缓冲区.

这是一个例子(I<收数据>) 在 SSH-1 中使用 I<register_handler> 看起来有点象 SSH-2:

    $ssh->register_handler("stdout", sub {
        my($channel, $buffer) = @_;
        print "I received this: ", $buffer->bytes;
    });


=back

=head1 ADVANCED METHODS

Your basic SSH needs will hopefully be met by the methods listed
above. If they're not, however, you may want to use some of the
additional methods listed here. Some of these are aimed at
end-users, while others are probably more useful for actually
writing an authentication module, or a cipher, etc.

=head2 $ssh->config

Returns the I<Net::SSH::Perl::Config> object managing the
configuration data for this SSH object. This is constructed
from data passed in to the constructor I<new> (see above),
merged with data read from the user and system configuration
files. See the I<Net::SSH::Perl::Config> docs for details
on methods you can call on this object (you'll probably
be more interested in the I<get> and I<set> methods).

=head2 $ssh->sock

Returns the socket connection to sshd. If your client is not
connected, dies.

=head2 $ssh->debug($msg)

If debugging is turned on for this session (see the I<debug>
parameter to the I<new> method, above), writes I<$msg> to
C<STDERR>. Otherwise nothing is done.

=head2 $ssh->incoming_data

传入的数据缓冲区, 是一个 I<Net::SSH::Perl::Buffer> 的类型的对象。返回  buffer 的对象.

这背后的理念是当我们套接字非阻塞，所以我们对输入进行缓冲和定期检查回去看看是否可以组成一个读过完整的数据包。如果我们有完整的数据包，我们取出来的传入的数据缓冲区，并对其进行处理，将其返回到调用它的地方。

这些数据是属于  I<Net::SSH::Perl::Packet> 的底层数据包层，除非你理解这个，不然你不要动这些数据.

=head2 $ssh->session_id

Returns the session ID, which is generated from the server's
host and server keys, and from the check bytes that it sends
along with the keys. The server may require the session ID to
be passed along in other packets, as well (for example, when
responding to RSA challenges).

=head2 $packet = $ssh->packet_start($packet_type)

Starts building a new packet of type I<$packet_type>. This is
just a handy method for lazy people. Internally it calls
I<Net::SSH::Perl::Packet::new>, so take a look at those docs
for more details.

=head1 SUPPORT

For samples/tutorials, take a look at the scripts in F<eg/> in
the distribution directory.

There is a mailing list for development discussion and usage
questions.  Posting is limited to subscribers only.  You can sign up
at http://lists.sourceforge.net/lists/listinfo/ssh-sftp-perl-users

Please report all bugs via rt.cpan.org at
https://rt.cpan.org/NoAuth/ReportBug.html?Queue=net%3A%3Assh%3A%3Aperl

=head1 AUTHOR

Current maintainer is David Robins, dbrobins@cpan.org.

Previous maintainer was Dave Rolsky, autarch@urth.org.

Originally written by Benjamin Trott.

=head1 COPYRIGHT

Copyright (c) 2001-2003 Benjamin Trott, Copyright (c) 2003-2008 David
Rolsky.  Copyright (c) David Robins.  All rights reserved.  This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included
with this module.

=cut
