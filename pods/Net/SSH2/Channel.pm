package Net::SSH2::Channel;

use strict;
use warnings;
use Carp;

# methods

sub shell {
    $_[0]->process('shell')
}

sub exec {
    $_[0]->process(exec => $_[1])
}

sub subsystem {
    $_[0]->process(subsystem => $_[1])
}

sub error {
    shift->session->error(@_)
}


# tie interface

sub PRINT {
    my $self = shift;
    my $sep = defined($,) ? $, : '';
    $self->write(join $sep, @_)
}

sub PRINTF {
    my $self = shift;
    $self->write(sprintf @_)
}

sub WRITE {
    my ($self, $buf, $len, $offset) = @_;
    $self->write(substr($buf, $offset, $len))
}

sub READLINE {
    my $self = shift;
    return if $self->eof;

    if (wantarray) {
        my @lines;
        my $line;
        push @lines, $line while defined($line = $self->READLINE);
        return @lines;
    }
    
    my ($line, $eol, $c) = ('', $/);
    $line .= $c while $line !~ /\Q$eol\E$/ and defined($c = $self->GETC);
    length($line) ? $line : undef
}

sub GETC {
    my $self = shift;
    my $buf;
    my @poll = ({ handle => $self, events => 'in' });
    return
     unless $self->session->poll(250, \@poll) and $poll[0]->{revents}->{in};
    $self->read($buf, 1) ? $buf : undef
}

sub READ {
    my ($self, $rbuf, $len, $offset) = @_;
    my ($tmp, $count);
    return unless defined($count = $self->read($tmp, $len));
    substr($$rbuf, $offset) = $tmp;
    $count
}

sub CLOSE {
    &close
}

sub BINMODE {
}

sub EOF {
    &eof
}

1;
__END__

=head1 NAME

Net::SSH2::Channel - SSH 2 channel object

=head1 DESCRIPTION

这个 channel 的通道对象是由 L<Net::SSH2> 的 C<channel> 方法创建。作为一个对象，他同时也是一个 tied 的句柄. 在  L<Net::SSH2> 中有个 C<poll> 的方法能检查是否可以进行读写和其它条件.

=head2 setenv ( key, value ... )

设置远程的环境变量。注意, 大多数时候不允许自由设置环境变量。 这个在一个列表中设置所需要的 key 和值。返回成功的设置。

=head2 blocking ( flag )

启用或禁用阻塞。请注意，这是在 libssh2 后实现的，通过设置每个会话标志; 它相当于为L<Net::SSH2::blocking>。

=head2 eof

如果远程服务器发送 EOF 会返回 true.

=head2 send_eof

发送 EOF 到远程。EOF 发送后，也许不能发送更多的数据; 这时应关闭连接。

=head2 close

关掉这个通道(当然，在对象销毁时也会自动做这个);

=head2 wait_closed

等待一个远程关闭事件。必须已经看到远程 EOF。

=head2 exit_status

返回通道的程序退出状态。

=head2 pty ( terminal [, modes [, width [, height ]]] )

请求在一个通道上打开一个终端。如果提供 C<width> 和 C<height> 是指字符的宽度和高度（默认为80x24）;如果为负数，是以其像素的绝对值指定宽度和高度.

=head2 pty_size ( width, height )

请求发送一个终端上通道的大小的变化。 C<width> 和 C<height> 是指字符的宽度和高度; 果为负数，是以其像素的绝对值指定宽度和高度.

=head2 process ( request, message )

通道上启动一个进程. 可以看  L<shell>, L<exec>, L<subsystem>.

=head2 shell

在远程主机上启动一个shell。调用 L<process>("shell").

=head2 exec ( command )

在远程主机上执行命令调用; 调用 L<process>("exec", command). 注意，每通道只有一个能成功 (cp.  L<perlfunc/exec>);如果你想运行的一系列命令，考虑代替使用 L<shell>。

=head2 subsystem ( name )

在远程主机上执行 subsystem 调用; 调用  L<process>("subsystem", command).

=head2 ext_data ( mode )

设置扩展的数据处理模式：

=over 4

=item normal (default)

保持数据都存在于单独的通道; 意思就是讲标准输出和 stderr 是被分开来的。

=item ignore

忽略所有扩展数据。

=item merge

都合并到普通的通道.

=back

=head2 read ( buffer, size [, ext ] )

会尝试读取指定大小的缓冲区。并返回读取的字节数量，如果失败时返回 undef.如果 ext_data是设置的会从扩展的数据通道读取(stderr).

=head2 write ( buffer [, ext ] )

会尝试写数据到指定的缓冲区，并返回写入的字节数量，如果失败时返回 undef.果 ext_data 是设置的会写展的数据通道(stderr).

=head2 flush ( [ ext ] )

刷新通道，如果 ext 是设置的，也会刷新扩展通道。返回刷新的字节数。错误为 undef.

=head2 exit_signal

返回通道上执行的命令的退出信号。需要的libssh1.2.8或更高版本。

=head1 SEE ALSO

L<Net::SSH2>.

=head1 AUTHOR

David B. Robins, E<lt>dbrobins@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2005, 2006 by David B. Robins; all rights reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
