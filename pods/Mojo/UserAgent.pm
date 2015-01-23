package Mojo::UserAgent;
use Mojo::Base 'Mojo::EventEmitter';

# "Fry: Since when is the Internet about robbing people of their privacy?
#  Bender: August 6, 1991."
use Carp 'croak';
use List::Util 'first';
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::URL;
use Mojo::Util qw(deprecated monkey_patch);
use Mojo::UserAgent::CookieJar;
use Mojo::UserAgent::Transactor;
use Scalar::Util 'weaken';

use constant DEBUG => $ENV{MOJO_USERAGENT_DEBUG} || 0;

has ca              => sub { $ENV{MOJO_CA_FILE} };
has cert            => sub { $ENV{MOJO_CERT_FILE} };
has connect_timeout => sub { $ENV{MOJO_CONNECT_TIMEOUT} || 10 };
has cookie_jar      => sub { Mojo::UserAgent::CookieJar->new };
has [qw(http_proxy https_proxy local_address no_proxy)];
has inactivity_timeout => sub { $ENV{MOJO_INACTIVITY_TIMEOUT} // 20 };
has ioloop             => sub { Mojo::IOLoop->new };
has key                => sub { $ENV{MOJO_KEY_FILE} };
has max_connections    => 5;
has max_redirects => sub { $ENV{MOJO_MAX_REDIRECTS} || 0 };
has name => 'Mojolicious (Perl)';
has request_timeout => sub { $ENV{MOJO_REQUEST_TIMEOUT} // 0 };
has transactor => sub { Mojo::UserAgent::Transactor->new };

# Common HTTP methods
for my $name (qw(DELETE GET HEAD OPTIONS PATCH POST PUT)) {
  monkey_patch __PACKAGE__, lc($name), sub {
    my $self = shift;
    my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
    return $self->start($self->build_tx($name, @_), $cb);
  };
}

sub DESTROY { shift->_cleanup }

sub app {
  my ($self, $app) = @_;

  # Singleton application
  state $singleton;
  return $singleton = $app ? $app : $singleton unless ref $self;

  # Default to singleton application
  return $self->{app} || $singleton unless $app;
  $self->{app} = $app;
  return $self;
}

sub app_url {
  my $self = shift;
  $self->_server(@_);
  return Mojo::URL->new("$self->{proto}://localhost:$self->{port}/");
}

# DEPRECATED in Rainbow!
sub build_form_tx {
  deprecated 'Mojo::UserAgent::build_form_tx is DEPRECATED in favor of '
    . 'Mojo::UserAgent::build_tx';
  shift->transactor->form(@_);
}

# DEPRECATED in Rainbow!
sub build_json_tx {
  deprecated 'Mojo::UserAgent::build_json_tx is DEPRECATED in favor of '
    . 'Mojo::UserAgent::build_tx';
  shift->transactor->json(@_);
}

sub build_tx           { shift->transactor->tx(@_) }
sub build_websocket_tx { shift->transactor->websocket(@_) }

sub detect_proxy {
  my $self = shift;
  $self->http_proxy($ENV{HTTP_PROXY}   || $ENV{http_proxy});
  $self->https_proxy($ENV{HTTPS_PROXY} || $ENV{https_proxy});
  return $self->no_proxy([split /,/, $ENV{NO_PROXY} || $ENV{no_proxy} || '']);
}

sub need_proxy {
  my ($self, $host) = @_;
  return !first { $host =~ /\Q$_\E$/ } @{$self->no_proxy || []};
}

# DEPRECATED in Rainbow!
sub post_form {
  deprecated 'Mojo::UserAgent::post_form is DEPRECATED in favor of '
    . 'Mojo::UserAgent::post';
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  return $self->start($self->build_form_tx(@_), $cb);
}

# DEPRECATED in Rainbow!
sub post_json {
  deprecated 'Mojo::UserAgent::post_json is DEPRECATED in favor of '
    . 'Mojo::UserAgent::post';
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  return $self->start($self->build_json_tx(@_), $cb);
}

sub start {
  my ($self, $tx, $cb) = @_;

  # Non-blocking
  if ($cb) {
    warn "-- Non-blocking request (@{[$tx->req->url->to_abs]})\n" if DEBUG;
    unless ($self->{nb}) {
      croak 'Blocking request in progress' if keys %{$self->{connections}};
      warn "-- Switching to non-blocking mode\n" if DEBUG;
      $self->_cleanup;
      $self->{nb}++;
    }
    return $self->_start($tx, $cb);
  }

  # Blocking
  warn "-- Blocking request (@{[$tx->req->url->to_abs]})\n" if DEBUG;
  if ($self->{nb}) {
    croak 'Non-blocking requests in progress' if keys %{$self->{connections}};
    warn "-- Switching to blocking mode\n" if DEBUG;
    $self->_cleanup;
    delete $self->{nb};
  }
  $self->_start($tx => sub { shift->ioloop->stop; $tx = shift });
  $self->ioloop->start;

  return $tx;
}

sub websocket {
  my $self = shift;
  my $cb = ref $_[-1] eq 'CODE' ? pop : undef;
  $self->start($self->build_websocket_tx(@_), $cb);
}

sub _cache {
  my ($self, $name, $id) = @_;

  # Enqueue and enforce connection limit
  my $old = $self->{cache} ||= [];
  if ($id) {
    my $max = $self->max_connections;
    $self->_remove(shift(@$old)->[1]) while @$old > $max;
    push @$old, [$name, $id] if $max;
    return undef;
  }

  # Dequeue
  my $found;
  my $loop = $self->_loop;
  my $new = $self->{cache} = [];
  for my $cached (@$old) {

    # Search for id/name and remove corrupted connections
    if (!$found && ($cached->[1] eq $name || $cached->[0] eq $name)) {
      my $stream = $loop->stream($cached->[1]);
      if ($stream && !$stream->is_readable) { $found = $cached->[1] }
      else                                  { $loop->remove($cached->[1]) }
    }

    # Requeue
    else { push @$new, $cached }
  }

  return $found;
}

sub _cleanup {
  my $self = shift;
  return unless my $loop = $self->_loop;

  # Clean up active connections (by closing them)
  $self->_handle($_ => 1) for keys %{$self->{connections} || {}};

  # Clean up keep alive connections
  $loop->remove($_->[1]) for @{delete $self->{cache} || []};

  # Stop server
  delete $self->{server};
}

sub _connect {
  my ($self, $proto, $host, $port, $handle, $cb) = @_;

  weaken $self;
  my $id;
  return $id = $self->_loop->client(
    address       => $host,
    handle        => $handle,
    local_address => $self->local_address,
    port          => $port,
    timeout       => $self->connect_timeout,
    tls           => $proto eq 'https' ? 1 : 0,
    tls_ca        => $self->ca,
    tls_cert      => $self->cert,
    tls_key       => $self->key,
    sub {
      my ($loop, $err, $stream) = @_;

      # Connection error
      return unless $self;
      return $self->_error($id, $err) if $err;

      # Connection established
      $stream->on(timeout => sub { $self->_error($id, 'Inactivity timeout') });
      $stream->on(close => sub { $self->_handle($id => 1) });
      $stream->on(error => sub { $self && $self->_error($id, pop, 1) });
      $stream->on(read => sub { $self->_read($id => pop) });
      $cb->();
    }
  );
}

sub _connect_proxy {
  my ($self, $old, $cb) = @_;

  # Start CONNECT request
  return undef unless my $new = $self->transactor->proxy_connect($old);
  return $self->_start(
    $new => sub {
      my ($self, $tx) = @_;

      # CONNECT failed
      unless (($tx->res->code // '') eq '200') {
        $old->req->error('Proxy connection failed');
        return $self->_finish($old, $cb);
      }

      # Prevent proxy reassignment and start real transaction
      $old->req->proxy(0);
      return $self->_start($old->connection($tx->connection), $cb)
        unless $tx->req->url->protocol eq 'https';

      # TLS upgrade
      return unless my $id = $tx->connection;
      my $loop   = $self->_loop;
      my $handle = $loop->stream($id)->steal_handle;
      my $c      = delete $self->{connections}{$id};
      $loop->remove($id);
      weaken $self;
      $id = $self->_connect($self->transactor->endpoint($old),
        $handle, sub { $self->_start($old->connection($id), $cb) });
      $self->{connections}{$id} = $c;
    }
  );
}

sub _connected {
  my ($self, $id) = @_;

  # Inactivity timeout
  my $stream = $self->_loop->stream($id)->timeout($self->inactivity_timeout);

  # Store connection information in transaction
  my $tx     = $self->{connections}{$id}{tx}->connection($id);
  my $handle = $stream->handle;
  $tx->local_address($handle->sockhost)->local_port($handle->sockport);
  $tx->remote_address($handle->peerhost)->remote_port($handle->peerport);

  # Start writing
  weaken $self;
  $tx->on(resume => sub { $self->_write($id) });
  $self->_write($id);
}

sub _connection {
  my ($self, $tx, $cb) = @_;

  # Reuse connection
  my $id = $tx->connection;
  my ($proto, $host, $port) = $self->transactor->endpoint($tx);
  $id ||= $self->_cache("$proto:$host:$port");
  if ($id && !ref $id) {
    warn "-- Reusing connection ($proto:$host:$port)\n" if DEBUG;
    $self->{connections}{$id} = {cb => $cb, tx => $tx};
    $tx->kept_alive(1) unless $tx->connection;
    $self->_connected($id);
    return $id;
  }

  # CONNECT request to proxy required
  if (my $id = $self->_connect_proxy($tx, $cb)) { return $id }

  # Connect
  warn "-- Connect ($proto:$host:$port)\n" if DEBUG;
  ($proto, $host, $port) = $self->transactor->peer($tx);
  weaken $self;
  $id = $self->_connect(
    ($proto, $host, $port, $id) => sub { $self->_connected($id) });
  $self->{connections}{$id} = {cb => $cb, tx => $tx};

  return $id;
}

sub _error {
  my ($self, $id, $err, $emit) = @_;
  if (my $tx = $self->{connections}{$id}{tx}) { $tx->res->error($err) }
  $self->emit(error => $err) if $emit;
  $self->_handle($id => $err);
}

sub _finish {
  my ($self, $tx, $cb, $close) = @_;

  # Remove code from parser errors
  my $res = $tx->res;
  if (my $err = $res->error) { $res->error($err) }

  else {

    # Premature connection close
    if ($close && !$res->code) { $res->error('Premature connection close') }

    # 400/500
    elsif ($res->is_status_class(400) || $res->is_status_class(500)) {
      $res->error($res->message, $res->code);
    }
  }

  $self->$cb($tx);
}

sub _handle {
  my ($self, $id, $close) = @_;

  # Remove request timeout
  my $c = $self->{connections}{$id};
  $self->_loop->remove($c->{timeout}) if $c->{timeout};

  # Finish WebSocket
  my $old = $c->{tx};
  if ($old && $old->is_websocket) {
    delete $self->{connections}{$id};
    $self->_remove($id, $close);
    $old->client_close;
  }

  # Upgrade connection to WebSocket
  elsif ($old && (my $new = $self->_upgrade($id))) {
    if (my $jar = $self->cookie_jar) { $jar->extract($old) }
    $old->client_close;
    $self->_finish($new, $c->{cb});
    $new->client_read($old->res->leftovers);
  }

  # Finish normal connection
  else {
    $self->_remove($id, $close);
    return unless $old;
    if (my $jar = $self->cookie_jar) { $jar->extract($old) }
    $old->client_close;

    # Handle redirects
    $self->_finish($new || $old, $c->{cb}, $close)
      unless $self->_redirect($c, $old);
  }
}

sub _loop { $_[0]{nb} ? Mojo::IOLoop->singleton : $_[0]->ioloop }

sub _read {
  my ($self, $id, $chunk) = @_;

  # Corrupted connection
  return                     unless my $c  = $self->{connections}{$id};
  return $self->_remove($id) unless my $tx = $c->{tx};

  # Process incoming data
  warn "-- Client <<< Server (@{[$tx->req->url->to_abs]})\n$chunk\n" if DEBUG;
  $tx->client_read($chunk);
  if    ($tx->is_finished)     { $self->_handle($id) }
  elsif ($c->{tx}->is_writing) { $self->_write($id) }
}

sub _remove {
  my ($self, $id, $close) = @_;

  # Close connection
  my $tx = (delete($self->{connections}{$id}) || {})->{tx};
  unless (!$close && $tx && $tx->keep_alive && !$tx->error) {
    $self->_cache($id);
    return $self->_loop->remove($id);
  }

  # Keep connection alive
  $self->_cache(join(':', $self->transactor->endpoint($tx)), $id)
    unless $tx->req->method eq 'CONNECT' && ($tx->res->code // '') eq '200';
}

sub _redirect {
  my ($self, $c, $old) = @_;

  # Follow redirect unless the maximum has been reached already
  return undef unless my $new = $self->transactor->redirect($old);
  my $redirects = delete $c->{redirects} || 0;
  return undef unless $redirects < $self->max_redirects;
  my $id = $self->_start($new, delete $c->{cb});

  return $self->{connections}{$id}{redirects} = $redirects + 1;
}

sub _server {
  my ($self, $proto) = @_;

  # Reuse server
  return $self->{server} if $self->{server} && !$proto;

  # Start application server
  my $loop   = $self->_loop;
  my $server = $self->{server}
    = Mojo::Server::Daemon->new(ioloop => $loop, silent => 1);
  my $port = $self->{port} ||= $loop->generate_port;
  die "Couldn't find a free TCP port for application.\n" unless $port;
  $self->{proto} = $proto ||= 'http';
  $server->listen(["$proto://127.0.0.1:$port"])->start;
  warn "-- Application server started ($proto://127.0.0.1:$port)\n" if DEBUG;
  return $server;
}

sub _start {
  my ($self, $tx, $cb) = @_;

  # Embedded server (update application if necessary)
  my $req = $tx->req;
  my $url = $req->url;
  if ($self->{port} || !$url->is_abs) {
    if (my $app = $self->app) { $self->_server->app($app) }
    my $base = $self->app_url;
    $url->scheme($base->scheme)->authority($base->authority)
      unless $url->is_abs;
  }

  # Proxy
  $self->detect_proxy if $ENV{MOJO_PROXY};
  my $proto = $url->protocol;
  if ($self->need_proxy($url->host)) {

    # HTTP proxy
    my $http = $self->http_proxy;
    $req->proxy($http) if $http && !defined $req->proxy && $proto eq 'http';

    # HTTPS proxy
    my $https = $self->https_proxy;
    $req->proxy($https) if $https && !defined $req->proxy && $proto eq 'https';
  }

  # We identify ourselves and accept gzip compression
  my $headers = $req->headers;
  $headers->user_agent($self->name) unless $headers->user_agent;
  $headers->accept_encoding('gzip') unless $headers->accept_encoding;
  if (my $jar = $self->cookie_jar) { $jar->inject($tx) }

  # Connect and add request timeout if necessary
  my $id = $self->emit(start => $tx)->_connection($tx, $cb);
  if (my $timeout = $self->request_timeout) {
    weaken $self;
    $self->{connections}{$id}{timeout} = $self->_loop->timer(
      $timeout => sub { $self->_error($id => 'Request timeout') });
  }

  return $id;
}

sub _upgrade {
  my ($self, $id) = @_;

  my $c = $self->{connections}{$id};
  return undef unless my $new = $self->transactor->upgrade($c->{tx});
  weaken $self;
  $new->on(resume => sub { $self->_write($id) });

  return $c->{tx} = $new;
}

sub _write {
  my ($self, $id) = @_;

  # Get and write chunk
  return unless my $c  = $self->{connections}{$id};
  return unless my $tx = $c->{tx};
  return unless $tx->is_writing;
  return if $c->{writing}++;
  my $chunk = $tx->client_write;
  delete $c->{writing};
  warn "-- Client >>> Server (@{[$tx->req->url->to_abs]})\n$chunk\n" if DEBUG;
  my $stream = $self->_loop->stream($id)->write($chunk);
  $self->_handle($id) if $tx->is_finished;

  # Continue writing
  return unless $tx->is_writing;
  weaken $self;
  $stream->write('' => sub { $self->_write($id) });
}

1;

=encoding utf8

=head1 NAME

Mojo::UserAgent - Non-blocking I/O HTTP and WebSocket user agent

=head1 SYNOPSIS

  use Mojo::UserAgent;

  # 如果方法后面直接跟一个哈希引用, 表示所要发送的定制的 header

  # 对 Unicode snowman 发关 hello 的参数，并加上 "Do Not Track" 的 header 
  my $ua = Mojo::UserAgent->new;
  say $ua->get('www.☃.net?hello=there' => {DNT => 1})->res->body;

  # 对 Form POST 进行异常处理
  my $tx = $ua->post('search.cpan.org/search' => form => {q => 'mojo'});
  if (my $res = $tx->success) { say $res->body }
  else {
    my ($err, $code) = $tx->error;
    die "$err->{code} response: $err->{message}" if $err->{code};
    die "Connection error: $err->{message}";
  }

  # 使用 Basic authentication 发出的 JSON 的 API 请求
  say $ua->get('https://sri:s3cret@search.twitter.com/search.json?q=perl')
    ->res->json('/results/0/text');

  # 从 HTML 和 XML 的资源中提取数据
  say $ua->get('www.perl.org')->res->dom->html->head->title->text;

  # 对这个新闻站点剥下最新的头条信息, 这使用了 CSS 的选择器
  say $ua->get('perlnews.org')->res->dom('h2 > a')->text->shuffle;

  # IPv6 PUT request with content
  my $tx
    = $ua->put('[::1]:3000' => {'Content-Type' => 'text/plain'} => 'Hello!');

  # 取得最新的 Mojolicious
  $ua->max_redirects(5)->get('latest.mojolicio.us')
    ->res->content->asset->move_to('/Users/sri/mojo.tar.gz');

  # TLS certificate authentication and JSON POST
  # 使用 TLS 的认证和使用 JSON 的 POST
  my $tx = $ua->cert('tls.crt')->key('tls.key')
    ->post('https://mojolicio.us' => json => {top => 'secret'});

  # 非阻塞并发请求
  my $delay = Mojo::IOLoop->delay(sub {
    my ($delay, @titles) = @_;
    say for @titles;
  });
  for my $url ('mojolicio.us', 'cpan.org') {
    my $end = $delay->begin(0);
    $ua->get($url => sub {
      my ($ua, $tx) = @_;
      $end->($tx->res->dom->at('title')->text);
    });
  }
  $delay->wait;

  # Non-blocking WebSocket connection sending and receiving JSON messages
  $ua->websocket('ws://example.com/echo.json' => sub {
    my ($ua, $tx) = @_;
    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
    $tx->on(json => sub {
      my ($tx, $hash) = @_;
      say "WebSocket message via JSON: $hash->{msg}";
      $tx->finish;
    });
    $tx->send({json => {msg => 'Hello World!'}});
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DESCRIPTION

L<Mojo::UserAgent> 是一个全功能的非阻塞 I/O HTTP 和 WebSocket 的用户代理, 支持 IPv6, TLS, SNI, IDNA, Comet (long polling), keep-alive, connection
pooling, timeout, cookie, multipart, proxy, gzip 压缩和多种事件循环支持.

如果一个新的进程 fork 产生时, 全部的连接相关的信息会被 reset. 所以这个允许多个进程安全的共享 L<Mojo::UserAgent> 对象.



为了更好的可扩展性 (epoll, kqueue) 和支持 IPv6 与 TLS, 可以在 L<Mojo::IOLoop> 中可选的模块 L<EV> (4.0+), L<IO::Socket::IP> (0.20+) 和  L<IO::Socket::SSL> (1.84+) 会自动的发现. 单独的特性象  MOJO_NO_IPV6 和 MOJO_NO_TLS 可以通过环境变量来禁用.

看 L<Mojolicious::Guides::Cookbook> 有更多信息.

=head1 事件

L<Mojo::UserAgent> 继承全部的 L<Mojo::EventEmitter> 的事件, 并支持下面这些.

=head2 error

  $ua->on(error => sub {
    my ($ua, $err) = @_;
    ...
  });

当如果有错误时, 整个事件就不在处理.

  $ua->on(error => sub {
    my ($ua, $err) = @_;
    say "This looks bad: $err";
  });

=head2 start

  $ua->on(start => sub {
    my ($ua, $tx) = @_;
    ...
  });

当任何新的事务处理即将开始的时候, 但并没发出请求, 这包含自动的准备 proxy 的 C<CONNECT> 请求和随后的重定向.

  $ua->on(start => sub {
    my ($ua, $tx) = @_;
    $tx->req->headers->header('X-Bender' => 'Bite my shiny metal ass!');
  });

=head1 属性

L<Mojo::UserAgent> implements the following attributes.

=head2 ca

  my $ca = $ua->ca;
  $ua    = $ua->ca('/etc/tls/ca.crt');

指定 TLS 证书授权文件所在路径, 默认是 MOJO_CA_FILE 环境变量的值. 这也会也激活主机名验证.

  # Show certificate authorities for debugging
  IO::Socket::SSL::set_defaults(
    SSL_verify_callback => sub { say "Authority: $_[2]" and return $_[0] });

=head2 cert

  my $cert = $ua->cert;
  $ua      = $ua->cert('/etc/tls/client.crt');

指定 TLS 证书文件所在路径, 默认是 MOJO_CERT_FILE 环境变量的值.

=head2 connect_timeout

  my $timeout = $ua->connect_timeout;
  $ua         = $ua->connect_timeout(5);

最大的建立连接所需要的秒数, 如果超过会被取消, 默认是 MOJO_CONNECT_TIMEOUT 环境变量的值或者是 C<10>.

=head2 cookie_jar

  my $cookie_jar = $ua->cookie_jar;
  $ua            = $ua->cookie_jar(Mojo::UserAgent::CookieJar->new);

用于该用户代理的请求的 Cookie jar, 默认是 L<Mojo::UserAgent::CookieJar> 对象.

  # Disable cookie jar
  $ua->cookie_jar(0);

=head2 inactivity_timeout

  my $timeout = $ua->inactivity_timeout;
  $ua         = $ua->inactivity_timeout(15);

最大的连接上去但不活跃的时间, 超过会被关闭. 默认为 MOJO_INACTIVITY_TIMEOUT 环境变量的值或者是 C<20>. 如果设置成 0 的值会允许连接无限期地处于非活动状态.

=head2 ioloop

  my $loop = $ua->ioloop;
  $ua      = $ua->ioloop(Mojo::IOLoop->new);

事件循环对象用于阻塞 I/O 操作, 默认的是 L<Mojo::IOLoop>  对象.

=head2 key

  my $key = $ua->key;
  $ua     = $ua->key('/etc/tls/client.crt');

TLS 密钥文件的路径, 默认为 MOJO_KEY_FILE 环境变量的值.

=head2 local_address

  my $address = $ua->local_address;
  $ua         = $ua->local_address('127.0.0.1');

本地绑定的地址.

=head2 max_connections

  my $max = $ua->max_connections;
  $ua     = $ua->max_connections(5);

在开始关掉老的缓存的连接之前用户代理的 UA 能保持最大活动连接的数量. 默认为 C<5>.

=head2 max_redirects

  my $max = $ua->max_redirects;
  $ua     = $ua->max_redirects(3);

用户代理所能保持的最大的重定向的数量, 超出就会 fail. 默认是 MOJO_MAX_REDIRECTS 环境变量的值或者 C<0>.

=head2 proxy

  my $proxy = $ua->proxy;
  $ua       = $ua->proxy(Mojo::UserAgent::Proxy->new);

代理管理, 默认是使用 L<Mojo::UserAgent::Proxy> 的对象

  # 自动发现代理服务从环境变量
  $ua->proxy->detect;

=head2 request_timeout

  my $timeout = $ua->request_timeout;
  $ua         = $ua->request_timeout(5);

建议的连接所能保持最大的秒数, 发送请求并且等着接收时连接所能保持最秒数. 超过就会关闭. 默认使用 MOJO_REQUEST_TIMEOUT 环境变量的值或者 C<0>. 设置这个值为 C<0> 会无限期地等待直到接收. 这个超时会在每次重定向时重新 reset.

  # Total limit of 5 seconds, of which 3 seconds may be spent connecting
  $ua->max_redirects(0)->connect_timeout(3)->request_timeout(5);

=head2 server

  my $server = $ua->server;
  $ua        = $ua->server(Mojo::UserAgent::Server->new);

应用服务器相对的 URL 会被 L<Mojo::UserAgent::Server> 对象处理.

  # Introspect
  say for @{$ua->server->app->secrets};

  # Change log level
  $ua->server->app->log->level('fatal');

  # Port currently used for processing relative URLs blocking
  say $ua->server->url->port;

  # Port currently used for processing relative URLs non-blocking
  say $ua->server->nb_url->port;

=head2 transactor

  my $t = $ua->transactor;
  $ua   = $ua->transactor(Mojo::UserAgent::Transactor->new);

Transaction 默认是 L<Mojo::UserAgent::Transactor> 对象.

=head1 METHODS

L<Mojo::UserAgent> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 build_tx

  my $tx = $ua->build_tx(GET => 'kraih.com');
  my $tx = $ua->build_tx(PUT => 'http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->build_tx(
    PUT => 'http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->build_tx(
    PUT => 'http://kraih.com' => {DNT => 1} => json => {a => 'b'});

L<Mojo::UserAgent::Transactor/"tx"> 用于生成 L<Mojo::Transaction::HTTP> 对象.

  # Request with cookie
  my $tx = $ua->build_tx(GET => 'kraih.com');
  $tx->req->cookies({name => 'foo', value => 'bar'});
  $ua->start($tx);

=head2 build_websocket_tx

  my $tx = $ua->build_websocket_tx('ws://localhost:3000');
  my $tx = $ua->build_websocket_tx('ws://localhost:3000' => {DNT => 1});

L<Mojo::UserAgent::Transactor/"websocket"> 用于生成 L<Mojo::Transaction::HTTP> 对象.

=head2 delete

  my $tx = $ua->delete('kraih.com');
  my $tx = $ua->delete('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->delete(
    'http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->delete(
    'http://kraih.com' => {DNT => 1} => json => {a => 'b'});

执行阻塞的 HTTP C<DELETE> 请求并返回 L<Mojo::Transaction::HTTP> 的对象, 使用 L<Mojo::UserAgent::Transactor/"tx"> 相同的参数 ( 除了方法 ). 你可以在后面加入回调来执行请求非阻塞的请求.

  $ua->delete('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 get

  my $tx = $ua->get('kraih.com');
  my $tx = $ua->get('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->get('http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->get('http://kraih.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<GET> 的请求.

  $ua->get('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 head

  my $tx = $ua->head('kraih.com');
  my $tx = $ua->head('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->head('http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->head('http://kraih.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<HEAD> 的请求.

  $ua->head('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 options

  my $tx = $ua->options('example.com');
  my $tx = $ua->options('http://example.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->options(
    'http://example.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->options(
    'http://example.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<OPTIONS> 的请求.

  $ua->options('http://example.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 patch

  my $tx = $ua->patch('kraih.com');
  my $tx = $ua->patch('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->patch('http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->patch('http://kraih.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<PATCH> 的请求.

  $ua->patch('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 post

  my $tx = $ua->post('kraih.com');
  my $tx = $ua->post('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->post('http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->post('http://kraih.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<POST> 的请求.

  $ua->post('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 put

  my $tx = $ua->put('kraih.com');
  my $tx = $ua->put('http://kraih.com' => {DNT => 1} => 'Hi!');
  my $tx = $ua->put('http://kraih.com' => {DNT => 1} => form => {a => 'b'});
  my $tx = $ua->put('http://kraih.com' => {DNT => 1} => json => {a => 'b'});

同上, 执行的是 HTTP C<PUT> 的请求.

  $ua->put('http://kraih.com' => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 start

  my $tx = $ua->start(Mojo::Transaction::HTTP->new);

执行阻塞的请求. 你可以在后面加一个回调来执行非阻塞的请求.

  my $tx = $ua->build_tx(GET => 'http://kraih.com');
  $ua->start($tx => sub {
    my ($ua, $tx) = @_;
    say $tx->res->body;
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head2 websocket

  $ua->websocket('ws://localhost:3000' => sub {...});
  $ua->websocket('ws://localhost:3000' => {DNT => 1} => sub {...});

Open a non-blocking WebSocket connection with transparent handshake, takes the
same arguments as L<Mojo::UserAgent::Transactor/"websocket">. The callback
will receive either a L<Mojo::Transaction::WebSocket> or
L<Mojo::Transaction::HTTP> object.

  $ua->websocket('ws://localhost:3000/echo' => sub {
    my ($ua, $tx) = @_;
    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;
    $tx->on(finish => sub {
      my ($tx, $code, $reason) = @_;
      say "WebSocket closed with status $code.";
    });
    $tx->on(message => sub {
      my ($tx, $msg) = @_;
      say "WebSocket message: $msg";
      $tx->finish;
    });
    $tx->send('Hi!');
  });
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

=head1 DEBUGGING

你可以打开 MOJO_USERAGENT_DEBUG 的环境变量来进行高级的调试信息, 默认会输出到标准错误.

  MOJO_USERAGENT_DEBUG=1

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
