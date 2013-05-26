package Mojolicious::Controller;
use Mojo::Base -base;

use Carp ();
use Mojo::ByteStream;
use Mojo::Cookie::Response;
use Mojo::Exception;
use Mojo::Transaction::HTTP;
use Mojo::URL;
use Mojo::Util;
use Mojolicious;
use Mojolicious::Routes::Match;
use Scalar::Util ();

has app => sub { Mojolicious->new };
has match => sub {
  Mojolicious::Routes::Match->new(GET => '/')->root(shift->app->routes);
};
has tx => sub { Mojo::Transaction::HTTP->new };

# Reserved stash values
my %RESERVED = map { $_ => 1 } (
  qw(action app cb controller data extends format handler json layout),
  qw(namespace partial path status template text)
);

sub AUTOLOAD {
  my $self = shift;

  # Method
  my ($package, $method) = our $AUTOLOAD =~ /^([\w:]+)::(\w+)$/;
  Carp::croak("Undefined subroutine &${package}::$method called")
    unless Scalar::Util::blessed($self) && $self->isa(__PACKAGE__);

  # Call helper
  Carp::croak(qq{Can't locate object method "$method" via package "$package"})
    unless my $helper = $self->app->renderer->helpers->{$method};
  return $self->$helper(@_);
}

sub DESTROY { }

sub cookie {
  my ($self, $name, $value, $options) = @_;
  $options ||= {};

  # Response cookie
  if (defined $value) {

    # Cookie too big
    $self->app->log->error(qq{Cookie "$name" is bigger than 4096 bytes.})
      if length $value > 4096;

    # Create new cookie
    $self->res->cookies(
      Mojo::Cookie::Response->new(name => $name, value => $value, %$options));
    return $self;
  }

  # Request cookies
  return map { $_->value } $self->req->cookie($name) if wantarray;

  # Request cookie
  return undef unless my $cookie = $self->req->cookie($name);
  return $cookie->value;
}

sub finish {
  my ($self, $chunk) = @_;

  # WebSocket
  my $tx = $self->tx;
  $tx->finish and return $self if $tx->is_websocket;

  # Chunked stream
  if ($tx->res->is_chunked) {
    $self->write_chunk($chunk) if defined $chunk;
    return $self->write_chunk('');
  }

  # Normal stream
  $self->write($chunk) if defined $chunk;
  return $self->write('');
}

sub flash {
  my $self = shift;

  # Check old flash
  my $session = $self->session;
  return $session->{flash} ? $session->{flash}{$_[0]} : undef
    if @_ == 1 && !ref $_[0];

  # Initialize new flash and merge values
  my $flash = $session->{new_flash} ||= {};
  %$flash = (%$flash, %{@_ > 1 ? {@_} : $_[0]});

  return $self;
}

sub on {
  my ($self, $name, $cb) = @_;
  my $tx = $self->tx;
  $self->rendered(101) if $tx->is_websocket;
  return $tx->on($name => sub { shift and $self->$cb(@_) });
}

sub param {
  my ($self, $name) = (shift, shift);

  # Multiple names
  return map { scalar $self->param($_) } @$name if ref $name eq 'ARRAY';

  # List names
  my $captures = $self->stash->{'mojo.captures'} ||= {};
  my $req = $self->req;
  unless (defined $name) {
    my %seen;
    my @keys = grep { !$seen{$_}++ } $req->param;
    push @keys, grep { !$seen{$_}++ } map { $_->name } @{$req->uploads};
    push @keys, grep { !$RESERVED{$_} && !$seen{$_}++ } keys %$captures;
    return sort @keys;
  }

  # Override values
  if (@_) {
    $captures->{$name} = @_ > 1 ? [@_] : $_[0];
    return $self;
  }

  # Captured unreserved values
  if (!$RESERVED{$name} && defined(my $value = $captures->{$name})) {
    return ref $value eq 'ARRAY' ? wantarray ? @$value : $$value[0] : $value;
  }

  # Upload
  my $upload = $req->upload($name);
  return $upload if $upload;

  # Param values
  return $req->param($name);
}

sub redirect_to {
  my $self = shift;

  # Don't override 3xx status
  my $res = $self->res;
  $res->headers->location($self->url_for(@_)->to_abs);
  return $self->rendered($res->is_status_class(300) ? undef : 302);
}

sub render {
  my $self = shift;

  # Template may be first argument
  my $template = @_ % 2 && !ref $_[0] ? shift : undef;
  my $args = ref $_[0] ? $_[0] : {@_};
  $args->{template} = $template if $template;

  # Template
  my $stash = $self->stash;
  unless ($args->{template} || $stash->{template}) {

    # Normal default template
    my $controller = $args->{controller} || $stash->{controller};
    my $action     = $args->{action}     || $stash->{action};
    if ($controller && $action) {
      $stash->{template} = join '/',
        split(/-/, Mojo::Util::decamelize($controller)), $action;
    }

    # Try the route name if we don't have controller and action
    elsif (my $endpoint = $self->match->endpoint) {
      $stash->{template} = $endpoint->name;
    }
  }

  # Render
  my ($output, $type) = $self->app->renderer->render($self, $args);
  return undef unless defined $output;
  return Mojo::ByteStream->new($output) if $args->{partial};

  # Prepare response
  my $res = $self->res;
  $res->body($output) unless $res->body;
  my $headers = $res->headers;
  $headers->content_type($type) unless $headers->content_type;
  return !!$self->rendered($stash->{status});
}

sub render_data { shift->render(data => @_) }

sub render_exception {
  my ($self, $e) = @_;

  # Log exception
  my $app = $self->app;
  $app->log->error($e = Mojo::Exception->new($e));

  # Filtered stash snapshot
  my $stash = $self->stash;
  my %snapshot = map { $_ => $stash->{$_} }
    grep { !/^mojo\./ and defined $stash->{$_} } keys %$stash;

  # Render with fallbacks
  my $mode     = $app->mode;
  my $renderer = $app->renderer;
  my $options  = {
    exception => $e,
    snapshot  => \%snapshot,
    template  => "exception.$mode",
    format    => $stash->{format} || $renderer->default_format,
    handler   => undef,
    status    => 500
  };
  my $inline = $renderer->_bundled(
    $mode eq 'development' ? 'exception.development' : 'exception');
  return if $self->_fallbacks($options, 'exception', $inline);
  $self->_fallbacks({%$options, format => 'html'}, 'exception', $inline);
}

sub render_json { shift->render(json => @_) }

sub render_later { shift->stash('mojo.rendered' => 1) }

sub render_not_found {
  my $self = shift;

  # Render with fallbacks
  my $app      = $self->app;
  my $mode     = $app->mode;
  my $renderer = $app->renderer;
  my $format   = $self->stash->{format} || $renderer->default_format;
  my $options
    = {template => "not_found.$mode", format => $format, status => 404};
  my $inline = $renderer->_bundled(
    $mode eq 'development' ? 'not_found.development' : 'not_found');
  return if $self->_fallbacks($options, 'not_found', $inline);
  $self->_fallbacks({%$options, format => 'html'}, 'not_found', $inline);
}

sub render_partial {
  my $self = shift;
  my $template = @_ % 2 ? shift : undef;
  return $self->render(
    {@_, partial => 1, defined $template ? (template => $template) : ()});
}

sub render_static {
  my ($self, $file) = @_;
  my $app = $self->app;
  return !!$self->rendered if $app->static->serve($self, $file);
  $app->log->debug(qq{File "$file" not found, public directory missing?});
  return undef;
}

sub render_text { shift->render(text => @_) }

sub rendered {
  my ($self, $status) = @_;

  # Disable auto rendering and make sure we have a status
  my $res = $self->render_later->res;
  $res->code($status || 200) if $status || !$res->code;

  # Finish transaction
  unless ($self->stash->{'mojo.finished'}++) {
    my $app = $self->app;
    $app->plugins->emit_hook_reverse(after_dispatch => $self);
    $app->sessions->store($self);
  }
  $self->tx->resume;
  return $self;
}

sub req { shift->tx->req }
sub res { shift->tx->res }

sub respond_to {
  my $self = shift;
  my $args = ref $_[0] ? $_[0] : {@_};

  # Detect formats
  my $app     = $self->app;
  my @formats = @{$app->types->detect($self->req->headers->accept)};
  my $stash   = $self->stash;
  unless (@formats) {
    my $format = $stash->{format} || $self->req->param('format');
    push @formats, $format ? $format : $app->renderer->default_format;
  }

  # Find target
  my $target;
  for my $format (@formats) {
    next unless $target = $args->{$format};
    $stash->{format} = $format;
    last;
  }

  # Fallback
  unless ($target) {
    return $self->rendered(204) unless $target = $args->{any};
    delete $stash->{format};
  }

  # Dispatch
  ref $target eq 'CODE' ? $target->($self) : $self->render($target);
}

sub send {
  my ($self, $msg, $cb) = @_;
  my $tx = $self->tx;
  Carp::croak('No WebSocket connection to send message to')
    unless $tx->is_websocket;
  $tx->send($msg => sub { shift and $self->$cb(@_) if $cb });
  return $self->rendered(101);
}

sub session {
  my $self = shift;

  # Hash
  my $session = $self->stash->{'mojo.session'} ||= {};
  return $session unless @_;

  # Get
  return $session->{$_[0]} unless @_ > 1 || ref $_[0];

  # Set
  %$session = (%$session, %{ref $_[0] ? $_[0] : {@_}});

  return $self;
}

sub signed_cookie {
  my ($self, $name, $value, $options) = @_;

  # Response cookie
  my $secret = $self->stash->{'mojo.secret'};
  return $self->cookie($name,
    "$value--" . Mojo::Util::hmac_sha1_sum($value, $secret), $options)
    if defined $value;

  # Request cookies
  my @results;
  for my $value ($self->cookie($name)) {

    # Check signature
    if ($value =~ s/--([^\-]+)$//) {
      my $sig = $1;

      # Verified
      my $check = Mojo::Util::hmac_sha1_sum $value, $secret;
      if (Mojo::Util::secure_compare $sig, $check) { push @results, $value }

      # Bad cookie
      else {
        $self->app->log->debug(
          qq{Bad signed cookie "$name", possible hacking attempt.});
      }
    }

    # Not signed
    else { $self->app->log->debug(qq{Cookie "$name" not signed.}) }
  }

  return wantarray ? @results : $results[0];
}

sub stash {
  my $self = shift;

  # Hash
  my $stash = $self->{stash} ||= {};
  return $stash unless @_;

  # Get
  return $stash->{$_[0]} unless @_ > 1 || ref $_[0];

  # Set
  my $values = ref $_[0] ? $_[0] : {@_};
  for my $key (keys %$values) {
    $self->app->log->debug(qq{Careful, "$key" is a reserved stash value.})
      if $RESERVED{$key};
    $stash->{$key} = $values->{$key};
  }

  return $self;
}

sub ua { shift->app->ua }

sub url_for {
  my $self = shift;
  my $target = shift // '';

  # Absolute URL
  return $target
    if Scalar::Util::blessed($target) && $target->isa('Mojo::URL');
  return Mojo::URL->new($target) if $target =~ m!^\w+://!;

  # Base
  my $url  = Mojo::URL->new;
  my $req  = $self->req;
  my $base = $url->base($req->url->base->clone)->base->userinfo(undef);

  # Relative URL
  my $path = $url->path;
  if ($target =~ m!^/!) {
    if (my $prefix = $self->stash->{path}) {
      my $real = Mojo::Util::url_unescape($req->url->path->to_abs_string);
      $real = Mojo::Util::decode('UTF-8', $real) // $real;
      $real =~ s!/?$prefix$!$target!;
      $target = $real;
    }
    $url->parse($target);
  }

  # Route
  else {
    my ($generated, $ws) = $self->match->path_for($target, @_);
    $path->parse($generated) if $generated;

    # Fix trailing slash
    $path->trailing_slash(1)
      if (!$target || $target eq 'current') && $req->url->path->trailing_slash;

    # Fix scheme for WebSockets
    $base->scheme(($base->scheme // '') eq 'https' ? 'wss' : 'ws') if $ws;
  }

  # Make path absolute
  my $base_path = $base->path;
  unshift @{$path->parts}, @{$base_path->parts};
  $base_path->parts([])->trailing_slash(0);

  return $url;
}

sub write {
  my ($self, $chunk, $cb) = @_;
  ($cb, $chunk) = ($chunk, undef) if ref $chunk eq 'CODE';
  $self->res->write($chunk => sub { shift and $self->$cb(@_) if $cb });
  return $self->rendered;
}

sub write_chunk {
  my ($self, $chunk, $cb) = @_;
  ($cb, $chunk) = ($chunk, undef) if ref $chunk eq 'CODE';
  $self->res->write_chunk($chunk => sub { shift and $self->$cb(@_) if $cb });
  return $self->rendered;
}

sub _fallbacks {
  my ($self, $options, $template, $inline) = @_;

  # Mode specific template
  return 1 if $self->render($options);

  # Template
  $options->{template} = $template;
  return 1 if $self->render($options);

  # Inline template
  my $stash = $self->stash;
  return undef unless $stash->{format} eq 'html';
  delete $stash->{$_} for qw(extends layout);
  delete $options->{template};
  return $self->render(%$options, inline => $inline, handler => 'ep');
}

1;

=pod

=encoding utf-8

=head1 名称

Mojolicious::Controller - Controller 的基类 

=head1 概述

  # Controller
  package MyApp::Foo;
  use Mojo::Base 'Mojolicious::Controller';

  # Action
  sub bar {
    my $self = shift;
    my $name = $self->param('name');
    $self->res->headers->cache_control('max-age=1, no-cache');
    $self->render(json => {hello => $name});
  }

=head1 描述

L<Mojolicious::Controller> 是 L<Mojolicious> 中的 controllers 的基类。它也是 L<Mojolicious> 中默认的 controller 类.除非你在你的应用中自己设置了 C<controller_class> 。

=head1 ATTRIBUTES

L<Mojolicious::Controller> 是从 L<Mojo::Base> 中继承了所有的属性。它自己实现了如下新的一些。

=head2 C<app>

  my $app = $c->app;
  $c      = $c->app(Mojolicious->new);

这是应用回到调度的控制器上的引用。默认是 L<Mojolicious> 的对象。

  # Use application logger
  $c->app->log->debug('Hello Mojo!');

=head2 C<match>

  my $m = $c->match;
  $c    = $c->match(Mojolicious::Routes::Match->new);

为当前的请求进行路由，默认是 L<Mojolicious::Routes::Match> 对象。

  # Introspect
  my $foo = $c->match->endpoint->pattern->defaults->{foo};

=head2 C<tx>

  my $tx = $c->tx;
  $c     = $c->tx(Mojo::Transaction::HTTP->new);

当前 transaction 的处理程序，通常是  L<Mojo::Transaction::HTTP> or L<Mojo::Transaction::WebSocket> 的对象

  # Check peer information
  my $address = $c->tx->remote_address;

=head1 方法

L<Mojolicious::Controller> 从 L<Mojo::Base> 中继承了全部的方法，并扩展了如下新的。

=head2 C<cookie>

  my $value  = $c->cookie('foo');
  my @values = $c->cookie('foo');
  $c         = $c->cookie(foo => 'bar');
  $c         = $c->cookie(foo => 'bar', {path => '/'});

访问请求中传过来的 cookie 的值和创建新的响应的 cookies.

  # Create response cookie with domain
  $c->cookie(name => 'sebastian', {domain => 'mojolicio.us'});

=head2 C<finish>

  $c = $c->finish;
  $c = $c->finish('Bye!');

优雅地结束 WebSocket 的连接或 long poll 长轮询流.

=head2 C<flash>

  my $foo = $c->flash('foo');
  $c      = $c->flash({foo => 'bar'});
  $c      = $c->flash(foo => 'bar');

为了下一个请求，给数据进行持久化，存在 C<session> 中。

  # Show message after redirect
  $c->flash(message => 'User created successfully!');
  $c->redirect_to('show_user', id => 23);

=head2 C<on>

  my $cb = $c->on(finish => sub {...});

从 C<tx> 中订阅相关的事件回调，常用是 L<Mojo::Transaction::HTTP>  和  L<Mojo::Transaction::WebSocket> 的对象.

  # Emitted when the transaction has been finished
  $c->on(finish => sub {
    my $c = shift;
    $c->app->log->debug('We are done!');
  });

  # Emitted when new WebSocket messages arrive
  $c->on(message => sub {
    my ($c, $msg) = @_;
    $c->app->log->debug("Message: $msg");
  });

=head2 C<param>

  my @names       = $c->param;
  my $foo         = $c->param('foo');
  my @foo         = $c->param('foo');
  my ($foo, $bar) = $c->param(['foo', 'bar']);
  $c              = $c->param(foo => 'ba;r');
  $c              = $c->param(foo => qw(ba;r ba;z));

访问 GET/POST 的参数，文件上传的内容和 route 中占位符取的内容并不会存在这个中。
注意，此方法是在某些情况下，上下文敏感的，并因此需要小心使用.
每个GET/ POST参数可以有多个值，这可能会带来意想不到的后果。

  # List context is ambiguous and should be avoided
  my $hash = {foo => $self->param('foo')};

  # Better enforce scalar context
  my $hash = {foo => scalar $self->param('foo')};

  # The multi name form can also enforce scalar context
  my $hash = {foo => $self->param(['foo'])};

为了更好的控制，你也可以直接访问请求信息。

  # Only GET parameters
  my $foo = $c->req->url->query->param('foo');

  # Only GET and POST parameters
  my $foo = $c->req->param('foo');

  # Only file uploads
  my $foo = $c->req->upload('foo');

=head2 C<redirect_to>

  $c = $c->redirect_to('named');
  $c = $c->redirect_to('named', foo => 'bar');
  $c = $c->redirect_to('/path');
  $c = $c->redirect_to('http://127.0.0.1/foo/bar');

准备一个 C<302> 重定向的响应，这个有一些扩展的参数，和 C<url_for> 一样的参数 .

  # Conditional redirect
  return $c->redirect_to('login') unless $c->session('user');

  # Moved permanently
  $c->res->code(301);
  $c->redirect_to('some_route');

=head2 C<render>

  my $success = $c->render;
  my $success = $c->render(controller => 'foo', action => 'bar');
  my $success = $c->render({controller => 'foo', action => 'bar'});
  my $success = $c->render(template => 'foo/index');
  my $success = $c->render(template => 'index', format => 'html');
  my $success = $c->render(data => $bytes);
  my $success = $c->render(text => 'Hello!');
  my $success = $c->render(json => {foo => 'bar'});
  my $success = $c->render(handler => 'something');
  my $success = $c->render('foo/index');
  my $output  = $c->render('foo/index', partial => 1);

使用 L<Mojolicious::Renderer/"render"> 渲染内容。如果没有提供模板的名字会基于请求的路径和动作来生成。全部的值会合并到 C<stash>. 

=head2 C<render_data>

  $c->render_data($bytes);
  $c->render_data($bytes, format => 'png');

渲染给定的内容，类似 C<render_text> 但不会进行编码,数据以原始字节生成。所有的值会合并到C<stash>中。

  # Longer version
  $c->render(data => $bytes);

=head2 C<render_exception>

  $c->render_exception('Oops!');
  $c->render_exception(Mojo::Exception->new('Oops!'));

渲染出错时的 exception 模板 C<exception.$mode.$format.*> or C<exception.$format.*> 然后设置响应状态为 C<500>。

=head2 C<render_json>

  $c->render_json({foo => 'bar'});
  $c->render_json([1, 2, -3], status => 201);

渲染结果成 JSON 的数据结构，所有数据会合到 C<stash>.

  # Longer version
  $c->render(json => {foo => 'bar'});

=head2 C<render_later>

  $c = $c->render_later;

禁用自动渲染生成内容，来延迟 HTTP 的响应生成的时机，只要有必要的时候才会生成响应.大多用在异步的时候.

  # Delayed rendering
  $c->render_later;
  Mojo::IOLoop->timer(2 => sub {
    $c->render(text => 'Delayed by 2 seconds!');
  });

=head2 C<render_not_found>

  $c->render_not_found;

渲染不存在的 not found 模板  C<not_found.$mode.$format.*> or C<not_found.$format.*> 并设置状态码为 C<404>.

=head2 C<render_partial>

  my $output = $c->render_partial('menubar');
  my $output = $c->render_partial('menubar', format => 'txt');
  my $output = $c->render_partial(template => 'menubar');

和 C<render> 但返回渲染结果。

  # Longer version
  my $output = $c->render('menubar', partial => 1);

=head2 C<render_static>

  my $success = $c->render_static('images/logo.png');
  my $success = $c->render_static('../lib/MyApp.pm');

渲染一个静态的的文件使用 L<Mojolicious::Static/"serve">，通常从 C<public> 的目录或 C<DATA> 的部分，你的应用程序。请注意，此方法的目录。

=head2 C<render_text>

  $c->render_text('Hello World!');
  $c->render_text('Hello World!', layout => 'green');

渲染的如Perl字符的内容， 这将被编码成字节。所有的值会合并到 C<stash> 中。是 C<render_data> 的替代品，无需进行编码。需要注意的是这并没有改变响应的内容类型，默认情况下，这是 C<text/html;charset=UTF-8>。

  # Longer version
  $c->render(text => 'Hello World!');

  # Render "text/plain" response
  $c->render_text('Hello World!', format => 'txt');

=head2 C<rendered>

  $c = $c->rendered;
  $c = $c->rendered(302);

最后的响应状态和使用  C<after_dispatch> 插件的 hook 点，默认使用  C<200> 的响应状态码。

  # Stream content directly from file
  $c->res->content->asset(Mojo::Asset::File->new(path => '/etc/passwd'));
  $c->res->headers->content_type('text/plain');
  $c->rendered(200);

=head2 C<req>

  my $req = $c->req;

取得 L<Mojo::Message::Request> 的对象从 L<Mojo::Transaction/"req">.

  # Longer version
  my $req = $c->tx->req;

  # Extract request information
  my $userinfo = $c->req->url->userinfo;
  my $agent    = $c->req->headers->user_agent;
  my $body     = $c->req->body;
  my $foo      = $c->req->json('/23/foo');
  my $bar      = $c->req->dom('div.bar')->first->text;

=head2 C<res>

  my $res = $c->res;

取得 L<Mojo::Message::Response> 的对象从 L<Mojo::Transaction/"res">.

  # Longer version
  my $res = $c->tx->res;

  # Force file download by setting a custom response header
  $c->res->headers->content_disposition('attachment; filename=foo.png;');

=head2 C<respond_to>

  $c->respond_to(
    json => {json => {message => 'Welcome!'}},
    html => {template => 'welcome'},
    any  => sub {...}
  );

从 C<Accept> 请求头中选择最好的资源回应， C<format> 的 stash 值或者 C<format> 中的 GET/POST 的参数。

默认使用一个空的  C<204> 的响应。如果 C<Accept> 的请求头中包含多过一个 MIME 的类型会被忽略.因为浏览器通知不知道这个的意思。

  $c->respond_to(
    json => sub { $c->render_json({just => 'works'}) },
    xml  => {text => '<just>works</just>'},
    any  => {data => '', status => 204}
  );

=head2 C<send>

  $c = $c->send({binary => $bytes});
  $c = $c->send({text   => $bytes});
  $c = $c->send([$fin, $rsv1, $rsv2, $rsv3, $op, $bytes]);
  $c = $c->send($chars);
  $c = $c->send($chars => sub {...});

发送消息或通过 WebSocket 的无阻塞框架， 在这个中的 drain 回调函数会被调用一次当所有的数据都被写入时。

  # Send "Text" frame
  $c->send('Hello World!');

  # Send JSON object as "Text" frame
  $c->send({text => Mojo::JSON->new->encode({hello => 'world'})});

  # Send JSON object as "Binary" frame
  $c->send({binary => Mojo::JSON->new->encode({hello => 'world'})});

  # Send "Ping" frame
  $c->send([1, 0, 0, 0, 9, 'Hello World!']);

空闲的 WebSockets 的超时，你可能还需要增加闲置逾时，通常默认为 C<15> 秒。

  # Increase inactivity timeout for connection to 300 seconds
  Mojo::IOLoop->stream($c->tx->connection)->timeout(300);

=head2 C<session>

  my $session = $c->session;
  my $foo     = $c->session('foo');
  $c          = $c->session({foo => 'bar'});
  $c          = $c->session(foo => 'bar');

持久性数据存储，所有的会话数据 通过 L<Mojo::JSON> 序列化和存储在 C<HMAC-SHA1> 签署 cookies。需要注意的是 Cookies 通常中 4096 个字节的限制，取决于你使用什么浏览器。

  # Manipulate session
  $c->session->{foo} = 'bar';
  my $foo = $c->session->{foo};
  delete $c->session->{foo};

  # Expiration date in epoch seconds from now (persists between requests)
  $c->session(expiration => 604800);

  # Expiration date as absolute epoch time (only valid for one request)
  $c->session(expires => time + 604800);

  # Delete whole session by setting an expiration date in the past
  $c->session(expires => 1);

=head2 C<signed_cookie>

  my $value  = $c->signed_cookie('foo');
  my @values = $c->signed_cookie('foo');
  $c         = $c->signed_cookie(foo => 'bar');
  $c         = $c->signed_cookie(foo => 'bar', {path => '/'});

访问签名的请求 cookie 的值，并创建新的签名响应 cookie。 cookie 失败时 C<HMAC-SHA1> 签名验证将被自动删除。

=head2 C<stash>

  my $stash = $c->stash;
  my $foo   = $c->stash('foo');
  $c        = $c->stash({foo => 'bar'});
  $c        = $c->stash(foo => 'bar');

这个用来做非持久性数据存储和交换，这个的默认值可以设置 L<Mojolicious/"defaults">。
有许多藏匿的值有特殊的含义，是保留的，目前完整的列表是  C<action>, C<app>, C<cb>,
C<controller>, C<data>, C<extends>, C<format>, C<handler>, C<json>, C<layout>,
C<namespace>, C<partial>, C<path>, C<status>, C<template> and C<text>. Note
that all stash values with a C<mojo.*> prefix are reserved for internal use.

  # Manipulate stash
  $c->stash->{foo} = 'bar';
  my $foo = $c->stash->{foo};
  delete $c->stash->{foo};

=head2 C<ua>

  my $ua = $c->ua;

取得 L<Mojo::UserAgent> 的对象从 L<Mojo/"ua">.

  # Longer version
  my $ua = $c->app->ua;

  # Blocking
  my $tx = $c->ua->get('http://mojolicio.us');
  my $tx = $c->ua->post_form('http://kraih.com/login' => {user => 'mojo'});

  # Non-blocking
  $c->ua->get('http://mojolicio.us' => sub {
    my ($ua, $tx) = @_;
    $c->render_data($tx->res->body);
  });

  # Parallel non-blocking
  my $delay = Mojo::IOLoop->delay(sub {
    my ($delay, @titles) = @_;
    $c->render_json(\@titles);
  });
  for my $url ('http://mojolicio.us', 'https://metacpan.org') {
    $delay->begin;
    $c->ua->get($url => sub {
      my ($ua, $tx) = @_;
      $delay->end($tx->res->dom->html->head->title->text);
    });
  }

=head2 C<url_for>

  my $url = $c->url_for;
  my $url = $c->url_for(name => 'sebastian');
  my $url = $c->url_for('test', name => 'sebastian');
  my $url = $c->url_for('/perldoc');
  my $url = $c->url_for('http://mojolicio.us/perldoc');

生成可移植的  L<Mojo::URL> 对象的 route ，路径或 URL。
Generate a portable L<Mojo::URL> object with base for a route, path or URL.

  # "/perldoc?foo=bar" if application is deployed under "/"
  $c->url_for('/perldoc')->query(foo => 'bar');

  # "/myapp/perldoc?foo=bar" if application is deployed under "/myapp"
  $c->url_for('/perldoc')->query(foo => 'bar');

您也可以使用辅助性 helper  L<Mojolicious::Plugin::DefaultHelpers/"url_with"> 来从当前请求中继承请求的参数

  # "/list?q=mojo&page=2" if current request was for "/list?q=mojo&page=1"
  $c->url_with->query([page => 2]);

=head2 C<write>

  $c = $c->write;
  $c = $c->write('Hello!');
  $c = $c->write(sub {...});
  $c = $c->write('Hello!' => sub {...});

非阻塞写动态的内容，选项 drain 的回调函数被调用时所有的数据都被写入。

  # Keep connection alive (with Content-Length header)
  $c->res->headers->content_length(6);
  $c->write('Hel' => sub {
    my $c = shift;
    $c->write('lo!')
  });

  # Close connection when finished (without Content-Length header)
  $c->write('Hel' => sub {
    my $c = shift;
    $c->write('lo!' => sub {
      my $c = shift;
      $c->finish;
    });
  });

在 Comet (C<long polling>) 你可能还需要增加闲置逾时，通常默认为C <15>秒。

  # Increase inactivity timeout for connection to 300 seconds
  Mojo::IOLoop->stream($c->tx->connection)->timeout(300);

=head2 C<write_chunk>

  $c = $c->write_chunk;
  $c = $c->write_chunk('Hello!');
  $c = $c->write_chunk(sub {...});
  $c = $c->write_chunk('Hello!' => sub {...});

无阻塞的写入动态内容用来 C<chunked> 传输编码，当 drain 回调会被调用时所有数据已被写入。

  # Make sure previous chunk has been written before continuing
  $c->write_chunk('He' => sub {
    my $c = shift;
    $c->write_chunk('ll' => sub {
      my $c = shift;
      $c->finish('o!');
    });
  });

你可以调用 C<finish> 在任何的时候结束这个流.

  2
  He
  2
  ll
  2
  o!
  0

=head1 帮助

除了上面的属性和方法，你可以使用  L<Mojolicious::Controller> 的对象。在  L<Mojolicious::Plugin::DefaultHelpers> 和 L<Mojolicious::    Plugin::TagHelpers> 包含全部的 helpers 

  $c->layout('green');
  $c->title('Welcome!');

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
