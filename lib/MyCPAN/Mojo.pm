package MyCPAN::Mojo;
use Mojo::Base 'Mojolicious::Controller';

sub home {
    my $self = shift;

    # 如果请求的是 "get.mojolicio.us"
    return $self->render('installer', format => 'txt')
      if $self->req->url->base->host =~ /^get\./;

    # 得到最新版本的 mojo  
    return $self->redirect_to('http://www.github.com/kraih/mojo/tarball/master')
      if $self->req->url->base->host =~ /^latest\./;

    $self->render('index');
}

1;

