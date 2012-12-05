package MyCPAN;
use Mojo::Base 'Mojolicious';

sub startup {
    my $self = shift;
    $self->secret('MyCPAN');

    my $r = $self->routes;
    $r->route('/')->to('mojo#home')->name('mojo_home');
    $r->any( '/perldoc/*module')->to('pod#show');
}

1;
