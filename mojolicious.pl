#!/usr/bin/env perl

use utf8; 
use Mojolicious::Lite;

app->secret('foo')->config(hypnotoad => {listen => ['http://*:8000']});


# Documentation browser under "/perldoc" (this plugin requires Perl 5.10)
plugin 'PODRenderer';

# Analytics
#hook after_static_dispatch => sub {
#  my $self = shift;
#  $self->content_for(perldoc => $self->render_partial('analytics'));
#};

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

  # 如果请求的是 "get.mojolicio.us"
  return $self->render('installer', format => 'txt')
    if $self->req->url->base->host =~ /^get\./;

  # 得到最新版本的 mojo  
  return $self->redirect_to('http://www.github.com/kraih/mojo/tarball/master')
    if $self->req->url->base->host =~ /^latest\./;

  # Index
  $self->render('index');
};

app->start;
