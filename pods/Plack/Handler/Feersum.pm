package Plack::Handler::Feersum;
use warnings;
use strict;
use Feersum::Runner;
use base 'Feersum::Runner';
use Scalar::Util qw/weaken/;

sub assign_request_handler {
    my $self = shift;
    weaken $self;
    $self->{endjinn}->psgi_request_handler(shift);
    # Plack::Loader::Restarter will SIGTERM the parent
    $self->{_term} = EV::signal 'TERM', sub { $self->quit };
    return;
}

1;
__END__

=head1 NAME

Plack::Handler::Feersum - plack adapter for Feersum

=head1 SYNOPSIS

    plackup -s Feersum app.psgi
    plackup -s Feersum --listen localhost:8080 app.psgi
    plackup -s Feersum --pre-fork=4 -MMy::App -L delayed app.psgi

=head1 DESCRIPTION

这是用于给 C<plackup> 调用所封装的模块. 你可以在  C<< $ENV{PLACK_SERVER} >>  中设置 'Feersum' 或者使用 -s 的参数指定 plackup 来使用 Feersum .

=head2 实验的特性 Experimental Features

这个 C<--pre-fork=N> 参数用于指定 feersum 可以提前 fork 多少个子进程. 这个  L<Starlet> 中的 C<--preload-app> 参数目前并不支持. 这的 fork 是启动和应用程序加载之后 fork 的. (i.e. in the C<run()> method).

=head1 METHODS

=over 4

=item C<< assign_request_handler($app) >>

给 Feersum 分配 PSGI 的请求.

还设置了一个 SIGTERM 的处理调用 C<quit()> 的方法, 所以  L<Plack::Loader::Restarter> 可以正常工作.

=back

=head1 SEE ALSO

更多的功能看 L<Feersum::Runner> 它是这个的父类.

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
