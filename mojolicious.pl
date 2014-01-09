#!/usr/bin/env perl
use utf8; 
use Mojolicious::Lite;
use Smart::Comments;

app->secret('foo')->config(hypnotoad => {listen => ['http://*:8000']});

unshift @INC, '/data/mojo/mojo/pods';
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
