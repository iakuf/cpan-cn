#!/usr/bin/env perl
use utf8; 
use Mojolicious::Lite;
use Smart::Comments;
use Mojo::Util qw(decamelize encode slurp);
use Cwd qw(cwd);

# 给模板重起写自己的


BEGIN {
    use Mojolicious::Plugin::PODRenderer;
    no warnings 'redefine';
    package Mojolicious::Plugin::PODRenderer;

    *Mojolicious::Plugin::PODRenderer::_html = sub  {
		my ($c, $src) = @_;

		# Rewrite links
  		my $dom     = Mojo::DOM->new(_pod_to_html($src));
  		my $perldoc = $c->url_for('/perldoc/');
  		for my $e ($dom->find('a[href]')->each) {
  		  my $attrs = $e->attr;
  		  $attrs->{href} =~ s!::!/!gi
  		    if $attrs->{href} =~ s!^http://metacpan\.org/pod/!$perldoc!;
  		}

  		# Rewrite code blocks for syntax highlighting and correct indentation
  		for my $e ($dom->find('pre > code')->each) {
  		  $e->content(my $str = unindent $e->content);
  		  next if $str =~ /^\s*(?:\$|Usage:)\s+/m || $str !~ /[\$\@\%]\w|-&gt;\w/m;
  		  my $attrs = $e->attr;
  		  my $class = $attrs->{class};
  		  $attrs->{class} = defined $class ? "$class prettyprint" : 'prettyprint';
  		}

  		# Rewrite headers
  		my $toc = Mojo::URL->new->fragment('toc');
  		my @parts;
  		for my $e ($dom->find('h1, h2, h3')->each) {

  		  push @parts, [] if $e->type eq 'h1' || !@parts;
  		  my $anchor = $e->{id};
  		  my $link   = Mojo::URL->new->fragment($anchor);
  		  push @{$parts[-1]}, my $text = $e->all_text, $link;
  		  my $permalink = $c->link_to('#' => $link, class => 'permalink');
  		  $e->content($permalink . $c->link_to($text => $toc, id => $anchor));
  		}

  		# Try to find a title
  		my $title = 'Perldoc';
  		$dom->find('h1 + p')->first(sub { $title = shift->text });

  		# Combine everything to a proper response
  		$c->content_for(perldoc => "$dom");
  		$c->render(template => 'perldoc', title => $title, parts => \@parts); # 修改成本地读
    };
};

if ( app->log->is_level('debug') ) {
    no warnings 'redefine';
    *Mojo::Log::_format = sub {
        my ($self, $level, @lines) = @_;
        my @caller = caller(4);
        my $caller = join ' ', $caller[0], $caller[2];
        return '[' . localtime(time) . "][$level] [$caller] " . join("\n", @lines). "\n";
    }
}

app->config(hypnotoad => {listen => ['http://*:8000']});

# 使用自己目录的 pod
unshift @INC, '/data/fukai/mojo/pods';

plugin 'PODRenderer';

hook before_dispatch => sub {
  my $self = shift;
  # 重写 mojo.php-oa.com  的所有 perldoc 指向 cpan
  my $url = $self->req->url;
  if (  $url->base->host ne 'cpan.php-oa.com' and $url->path =~ /\/perldoc\/.*/ ) {
      $self->res->code(301);
      $self->redirect_to($self->req->url->to_abs->host("cpan.php-oa.com"));
  }
};

get '/' => sub {
  my $self = shift;

  return $self->render('cpan') if  $self->req->url->base->host =~ /^cpan\./;

  # Index
  $self->render('index');
};

app->start;


