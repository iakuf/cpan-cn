#!/usr/bin/env perl
use utf8; 
use Mojolicious::Lite;
use Smart::Comments;

app->secret('foo')->config(hypnotoad => {listen => ['http://*:8000']});


plugin 'PODRenderer';


# Redirect to main site
hook before_dispatch => sub {
  my $self = shift;
  return unless $self->req->url->base->host =~ /^(.*)mojolicious.org$/;
  $self->res->code(301);
  $self->redirect_to($self->req->url->to_abs->host("$1mojolicio.us"));
};

# Welcome to Mojolicious
get '/' => sub {
  my $self = shift;

  return $self->render('cpan') if $self->req->url->base->host =~ /^cpan\./;

  # 得到最新版本的 mojo  
  return $self->redirect_to('http://www.github.com/kraih/mojo/tarball/master')
    if $self->req->url->base->host =~ /^latest\./;

  # Index
  $self->render('index');
};


app->start;
