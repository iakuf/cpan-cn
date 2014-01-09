package DBIx::Connector;

use 5.006002;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connector::Driver;

our $VERSION = '0.53';

sub new {
    my $class = shift;
    my @args = @_;
    bless {
        _args      => sub { @args },
        _svp_depth => 0,
        _mode      => 'no_ping',
        _dond      => 1,
    } => $class;
}

sub DESTROY { $_[0]->disconnect if $_[0]->{_dond} }

sub _connect {
    my $self = shift;
    my @args = $self->{_args}->();
    my $dbh = $self->{_dbh} = do {
        if ($INC{'Apache/DBI.pm'} && $ENV{MOD_PERL}) {
            local $DBI::connect_via = 'connect'; # Disable Apache::DBI.
            DBI->connect( @args );
        } else {
            DBI->connect( @args );
        }
    } or return;

    # Modify default values.
    $dbh->STORE(AutoInactiveDestroy => 1) if DBI->VERSION > 1.613 && (
        @args < 4 || !exists $args[3]->{AutoInactiveDestroy}
    );

    $dbh->STORE(RaiseError => 1) if @args < 4 || (
        !exists $args[3]->{RaiseError} && !exists $args[3]->{HandleError}
    );

    # Where are we?
    $self->{_pid} = $$;
    $self->{_tid} = threads->tid if $INC{'threads.pm'};

    # Set up the driver and go!
    return $self->driver->_connect($dbh, @args);
}

sub driver {
    my $self = shift;
    return $self->{driver} if $self->{driver};

    my $driver = do {
        if (my $dbh = $self->{_dbh}) {
            $dbh->{Driver}{Name};
        } else {
            (DBI->parse_dsn( ($self->{_args}->())[0]) )[1];
        }
    };
    $self->{driver} = DBIx::Connector::Driver->new( $driver );
}

sub connect {
    my $self = shift->new(@_);
    $self->{_dond} = 0;
    $self->dbh;
}

sub dbh {
    my $self = shift;
    my $dbh = $self->_seems_connected or return $self->_connect;
    return $dbh if $self->{_in_run};
    return $self->connected ? $dbh : $self->_connect;
}

# Just like dbh(), except it doesn't ping the server.
sub _dbh {
    my $self = shift;
    $self->_seems_connected || $self->_connect;
}

sub connected {
    my $self = shift;
    return unless $self->_seems_connected;
    my $dbh = $self->{_dbh} or return;
    return $self->driver->ping($dbh);
}

sub mode {
    my $self = shift;
    return $self->{_mode} unless @_;
    require Carp && Carp::croak(qq{Invalid mode: "$_[0]"})
        unless $_[0] =~ /^(?:fixup|(?:no_)?ping)$/;
    $self->{_mode} = shift;
}

sub disconnect_on_destroy {
    my $self = shift;
    return $self->{_dond} unless @_;
    $self->{_dond} = !!shift;
}

sub in_txn {
    my $dbh = shift->{_dbh} or return;
    return !$dbh->FETCH('AutoCommit');
}

# returns true if there is a database handle and the PID and TID have not
# changed and the handle's Active attribute is true.
sub _seems_connected {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    if ( defined $self->{_tid} && $self->{_tid} != threads->tid ) {
        return;
    } elsif ( $self->{_pid} != $$ ) {
        # We've forked, so prevent the parent process handle from touching the
        # DB on DESTROY. Here in the child process, that could really screw
        # things up. This is superfluous when AutoInactiveDestroy is set, but
        # harmless. It's better to be proactive anyway.
        $dbh->STORE(InactiveDestroy => 1);
        return;
    }
    # Use FETCH() to avoid death when called from during global destruction.
    return $dbh->FETCH('Active') ? $dbh : undef;
}

sub disconnect {
    my $self = shift;
    if (my $dbh = $self->{_dbh}) {
        # Some databases need this to stop spewing warnings, according to
        # DBIx::Class::Storage::DBI.
        $dbh->STORE(CachedKids => {});
        $dbh->disconnect;
        $self->{_dbh} = undef;
    }
    return $self;
}

sub run {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    return $self->_fixup_run(@_) if $mode eq 'fixup';
    return $self->_run(@_);
  }

sub _run {
    my ($self, $code) = @_;
    my $dbh = $self->{_mode} eq 'ping' ? $self->dbh : $self->_dbh;
    local $self->{_in_run} = 1;
    return _exec( $dbh, $code, wantarray );
}

sub _fixup_run {
    my ($self, $code) = @_;
    my $dbh  = $self->_dbh;

    my $wantarray = wantarray;
    return _exec( $dbh, $code, $wantarray )
        if $self->{_in_run} || !$dbh->FETCH('AutoCommit');

    local $self->{_in_run} = 1;
    my ($err, @ret);
    TRY: {
        local $@;
        @ret = eval { _exec( $dbh, $code, $wantarray ) };
        $err = $@;
    }

    if ($err) {
        die $err if $self->connected;
        # Not connected. Try again.
        return _exec( $self->_connect, $code, $wantarray, @_ );
    }

    return $wantarray ? @ret : $ret[0];
}

sub txn {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    return $self->_txn_fixup_run(@_) if $mode eq 'fixup';
    return $self->_txn_run(@_);
}

sub _txn_run {
    my ($self, $code) = @_;
    my $driver = $self->driver;
    my $wantarray = wantarray;
    my $dbh = $self->{_mode} eq 'ping' ? $self->dbh : $self->_dbh;

    unless ($dbh->FETCH('AutoCommit')) {
        local $self->{_in_run}  = 1;
        return _exec( $dbh, $code, $wantarray );
    }

    my ($err, @ret);
    TRY: {
        local $@;
        eval {
            local $self->{_in_run}  = 1;
            $driver->begin_work($dbh);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->commit($dbh);
        };
        $err = $@;
    }

    if ($err) {
        $err = $driver->_rollback($dbh, $err);
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub _txn_fixup_run {
    my ($self, $code) = @_;
    my $dbh    = $self->_dbh;
    my $driver = $self->driver;

    my $wantarray = wantarray;
    local $self->{_in_run}  = 1;

    return _exec( $dbh, $code, $wantarray ) unless $dbh->FETCH('AutoCommit');

    my ($err, @ret);
    TRY: {
        local $@;
        eval {
            $driver->begin_work($dbh);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->commit($dbh);
        };
        $err = $@;
    }

    if ($err) {
        if ($self->connected) {
            $err = $driver->_rollback($dbh, $err);
            die $err;
        }

        # Not connected. Try again.
        $dbh = $self->_connect;
        TRY: {
            local $@;
            eval {
                $driver->begin_work($dbh);
                @ret = _exec( $dbh, $code, $wantarray );
                $driver->commit($dbh);
            };
            $err = $@;
        }
        if ($err) {
            $err = $driver->_rollback($dbh, $err);
            die $err;
        }
    }

    return $wantarray ? @ret : $ret[0];
}

sub svp {
    my $self = shift;
    my $dbh  = $self->{_dbh};

    # Gotta have a transaction.
    return $self->txn( @_ ) if !$dbh || $dbh->FETCH('AutoCommit');

    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    my $code = shift;

    my ($err, @ret);
    my $wantarray = wantarray;
    my $driver    = $self->driver;
    my $name      = "savepoint_$self->{_svp_depth}";
    ++$self->{_svp_depth};

    TRY: {
        local $@;
        eval {
            $driver->savepoint($dbh, $name);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->release($dbh, $name);
        };
        $err = $@;
    }
    --$self->{_svp_depth};

    if ($err) {
        # If we died, there is nothing to be done.
        if ($self->connected) {
            $err = $driver->_rollback_and_release($dbh, $name, $err);
        }
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub _exec {
    my ($dbh, $code, $wantarray) = @_;
    local $_ = $dbh;
    # Block prevents exiting via next or last, otherwise no commit/rollback.
    NOEXIT: {
        return $wantarray ? $code->($dbh) : scalar $code->($dbh)
            if defined $wantarray;
        return $code->($dbh);
    }
    return;
}

1;
__END__

=head1 Name

DBIx::Connector - 快速，安全的DBI连接和事务管理 

=head1 Synopsis

  use DBIx::Connector;

  # Create a connection.
  my $conn = DBIx::Connector->new($dsn, $username, $password, {
      RaiseError => 1,
      AutoCommit => 1,
  });

  # 取得数据库的句柄做一些操作.
  my $dbh  = $conn->dbh;
  $dbh->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );

  # Do something with the handle more efficiently.
  $conn->run(fixup => sub {
      $_->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );
  });

=head1 Description

DBIx::Connector 提供了一个简单的接口, 让我们快速和安全的进行 DBI 的连接和事务管理。连接到数据库过程是昂贵的, 你不希望次你需要运行一个查询时, 你的应用程序重新连接.
一个高效的做法是给数据库句柄一直保持连接, 以尽量减少额外开销. DBIx::Connector 可以帮你达到这样, 并且不用担心断开和坏掉的连接.

你可能知道 L<Apache::DBI|Apache::DBI> 通过 L<DBI> 中的 L<C<connect_cached()>|DBI/connect_cached> 来构造函数. DBIx::Connector 提供类似的功能并且工作的更加好, 为什么?

=over

=item * Fork Safety 进程安全

象 Apache::DBI, 但不同的是不使用 C<connect_cached()>, 在 C<fork> 的时候  DBIx::Connector 创建新的数据库连接. 象 L<mod_perl> 和 L<POE> 的应用都是这样.这个最好工作在 DBI 1.614 和这个版本以上.

=item * Thread Safety 线程安全

不同于 Apache::DBI 或 C<connect_cached()>, 在新的线程被生成时 DBIx::Connector 会创建新的数据库连接.
spawning a new thread can break database connections.

=item * Works Anywhere

不同于 Apache::DBI, DBIx::Connector 可以在任何地方运行, 不断只是 mod_perl 内部. 为什么要限制它啦?

=item * Explicit Interface

DBIx::Connector 有一个明确的接口. 这没什么象 Apache::DBI 奇怪的语法糖, 并且没有全局 cache.我亲自处理了几个 Apache::DBI 的问题, 并在二个项目中去掉了 C<connect_cached()>, 使用这些只有更多的陷阱来绊倒你. 

=item * Optimistic Execution

如果你使用 C<run()> 和 C<txn()>, 这数据库的句柄发送前并不会 ping 服务器. 在 99% 的时候,数据库本身连接不会有问题. 这样不使用 ping 可以节省大量的开销.

=back

DBIx::Connector's other feature is transaction management. Borrowing an
interface from L<DBIx::Class>, DBIx::Connector offers an API that efficiently
handles the scoping of database transactions so that you needn't worry about
managing the transaction yourself. Even better, it offers an API for
savepoints if your database supports them. Within a transaction, you can scope
savepoints to behave like subtransactions, so that you can save some of your
work in a transaction even if part of it fails. See L<C<txn()>|/"txn"> and
L<C<svp()>|/"svp"> for the goods.

=head1 Usage

不同于 L<Apache::DBI> 和 L<C<connect_cached()>|DBI/connect_cached>, DBIx::Connector 并不会缓存数据库句柄. 而是, 对于给定的连接, 只要你想使用, 它就能保证连接一定存在(尽可能). 它主要实现是在安全的情况下创建连接, 并且保持这个连接,只要你需要使用它. 象下面这样创建.

  my $conn = DBIx::Connector->new(@args);

这样你就能给连接存储在你应用程序当中, 在你的名字空间可以访问到的范围, 都很容易的访问到它, 由它来管理最难维护的数据库连接. 就算是在 fork （特别在DBI1.614及更高版本）和新的线程和调用 C<< $conn->dbh->disconnect >> 都没问题. 当你不需要使用它, 只需要离开这个名字空间的范围数据库就会自动关闭.

最终效果就是, 当你的代码只要需要连接, 就会挂到一个数据库的连接当中. 但这并没有象  L<Apache::DBI|Apache::DBI> and L<C<connect_cached()>|DBI/connect_cached> 当中那种使用神奇的连接缓存.

=head2 Execution Methods 执行的方法

这个 DBIx::Connector 的实际功能来源于执行的方法 L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">. 代替下面这个:

  $conn->dbh->do($query);

试试这个:

  $conn->run(sub { $_->do($query) }); # returns retval from the sub {...}

这个不同之处在于 C<run()> 方法会乐观地假设现有数据库句柄是连接的并执行这个代码引用, 而无需执行 ping 数据库来检查死活. 因为绝大多数时候, 这个连接还是会有效能正常的使用. 所以你每次使用  C<run()> (or C<txn()>) 的时候都节省一个 ping 查询的开销.

当然, 如果使用 C<run()> 时因为 DBI 上的数据库连接因为一些故障并不真的存在时会在次尝试. 这个 DBIx::Connector 也提供了另一种方式来解决这个问题, 就是: 连接模式 connection modes.

=head3 Connection Modes 连接模式

当调用  L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">, 时都可以使用这个内部的连接模式. 所支持的模式如下:

=over

=item * C<ping>

=item * C<fixup>

=item * C<no_ping>

=back

Use them via an optional first argument, like so:

  $conn->run(ping => sub { $_->do($query) });

Or set up a default mode via the C<mode()> accessor:

  $conn->mode('fixup');
  $conn->run(sub { $_->do($query) });

The return value of the block will be returned from the method call in scalar
or array context as appropriate, and the block can use C<wantarray> to
determine the context. Returning the value makes them handy for things like
constructing a statement handle:

  my $sth = $conn->run(fixup => sub {
      my $sth = $_->prepare('SELECT isbn, title, rating FROM books');
      $sth->execute;
      $sth;
  });

In C<ping> mode, C<run()> will ping the database I<before> running the block.
This is similar to what L<Apache::DBI> and the L<DBI>'s
L<C<connect_cached()>|DBI/connect_cached> method do to check the database
connection, and is the safest way to do so. If the ping fails, DBIx::Connector
will attempt to reconnect to the database before executing the block. However,
C<ping> mode does impose the overhead of the C<ping> ever time you use it.

In C<fixup> mode, DBIx::Connector executes the block without pinging the
database. But in the event the block throws an exception, if DBIx::Connector
finds that the database handle is no longer connected, it will reconnect to
the database and re-execute the block. Therefore, the code reference should
have B<no side-effects outside of the database,> as double-execution in the
event of a stale database connection could break something:

  my $count;
  $conn->run(fixup => sub { $count++ });
  say $count; # may be 1 or 2

C<fixup> is the most efficient connection mode. If you're confident that the
block will have no deleterious side-effects if run twice, this is the best
option to choose. If you decide that your block is likely to have too many
side-effects to execute more than once, you can simply switch to C<ping> mode.

The default is C<no_ping>, but you likely won't ever use it directly, and
isn't recommended in any event.

Simple, huh? Better still, go for the transaction management in
L<C<txn()>|/"txn"> and the savepoint management in L<C<svp()>|/"svp">. You
won't be sorry, I promise.

=head3 Rollback Exceptions

In the event of a rollback in L<C<txn()>|/"txn"> or L<C<svp()>|/"svp">, if the
rollback itself fails, a DBIx::Connector::TxnRollbackError or
DBIx::Connector::SvpRollbackError exception will be thrown, as appropriate.
These classes, which inherit from DBIx::Connector::RollbackError, stringify to
display both the rollback error and the transaction or savepoint error that
led to the rollback, something like this:

    Transaction aborted: No such table "foo" at foo.pl line 206.
    Transaction rollback failed: Invalid transaction ID at foo.pl line 203.

For finer-grained exception handling, you can access the individual errors via
accessors:

=over

=item C<error>

The transaction or savepoint error.

=item C<rollback_error>

The rollback error.

=back

For example:

  use Try::Tiny;
  $conn->txn(sub {
      try {
          # ...
      } catch {
          if (eval { $_->isa('DBIx::Connector::RollbackError') }) {
              say STDERR 'Transaction aborted: ', $_->error;
              say STDERR 'Rollback failed too: ', $_->rollback_error;
          } else {
              warn "Caught exception: $_";
          }
      };
  });

If a L<C<svp()>|/"svp"> rollback fails and its surrounding L<C<txn()>|/"txn">
rollback I<also> fails, the thrown DBIx::Connetor::TxnRollbackError exception
object will have the the savepoint rollback exception, which will be an
DBIx::Connetor::SvpRollbackError exception object in its C<error> attribute:

  use Try::Tiny;
  $conn->txn(sub {
      try {
          $conn->svp(sub { # ... });
      } catch {
          if (eval { $_->isa('DBIx::Connector::RollbackError') }) {
              if (eval { $_->error->isa('DBIx::Connector::SvpRollbackError') }) {
                  say STDERR 'Savepoint aborted: ', $_->error->error;
                  say STDERR 'Its rollback failed too: ', $_->error->rollback_error;
              } else {
                  say STDERR 'Transaction aborted: ', $_->error;
              }
              say STDERR 'Transaction rollback failed too: ', $_->rollback_error;
          } else {
              warn "Caught exception: $_";
          }
      };
  });

But most of the time, you should be fine with the stringified form of the
exception, which will look something like this:

    Transaction aborted: Savepoint aborted: No such table "bar" at foo.pl line 190.
    Savepoint rollback failed: Invalid savepoint name at foo.pl line 161.
    Transaction rollback failed: Invalid transaction identifier at fool.pl line 184.

This allows you to see you original SQL error, as well as the errors for the
savepoint rollback and transaction rollback failures.

=head1 Interface

And now for the nitty-gritty.

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connector->new($dsn, $username, $password, {
      RaiseError => 1,
      AutoCommit => 1,
  });

Constructs and returns a DBIx::Connector object. The supported arguments are
exactly the same as those supported by the L<DBI>. Default values for those
parameters vary from the DBI as follows:

=over

=item C<RaiseError>

Defaults to true if unspecified, and if C<HandleError> is unspecified. Use of
the C<RaiseError> attribute, or a C<HandleError> attribute that always throws
exceptions (such as that provided by L<Exception::Class::DBI>), is required
for the exception-handling functionality of L<C<run()>|/"run">,
L<C<txn()>|/"txn">, and L<C<svp()>|/"svp"> to work properly. Their explicit
use is therefor recommended if for proper error handling with these execution
methods.

=item C<AutoInactiveDestroy>

Added in L<DBI> 1.613. Defaults to true if unspecified. This is important for
safe disconnects across forking processes.

=back

In addition, explicitly setting C<AutoCommit> to true is strongly recommended
if you plan to use L<C<txn()>|/"txn"> or L<C<svp()>|/"svp">, as otherwise you
won't get the transactional scoping behavior of those two methods.

If you would like to execute custom logic each time a new connection to the
database is made you can pass a sub as the C<connected> key to the
C<Callbacks> parameter. See L<DBI/Callbacks> for usage and other available
callbacks.

Other attributes may be modified by individual drivers. See the documentation
for the drivers for details:

=over

=item L<DBIx::Connector::Driver::MSSQL>

=item L<DBIx::Connector::Driver::Oracle>

=item L<DBIx::Connector::Driver::Pg>

=item L<DBIx::Connector::Driver::SQLite>

=item L<DBIx::Connector::Driver::mysql>

=back

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connector->connect($dsn, $username, $password, \%attr);

语法糖:

  my $dbh = DBIx::Connector->new(@args)->dbh;

这个地方这个可能没有太多的意义, 因为通常你想使用 DBIx::Connector 的对象, 但如果你只想使用 L<DBI> 的话.

=head2 Instance Methods 实例方法

=head3 C<dbh>

  my $dbh = $conn->dbh;

反正一个数据库连接的句柄. 如果存在现有的,这会提供现有的句柄给你. 如果进程是 C<fork> 了以后或者产生了新线程, 这时数据库是可 ping 的, 就会实例代一个新的句柄, 并缓存起来并返回.

当代码块是通过 L<C<run()>|/"run">, L<C<txn()>|/"txn">, 或者 L<C<svp()>|/"svp"> 调用, 这时 C<dbh()> 句柄会假定数据库的 ping 的死活检查是通过其它的方法来检查, 并跳过 C<ping> 的检查. 事实上，这最好这么做，所以如果你正在做大量的非数据库本身需要处理的那些, 时间都会用在死活检查上.

=head3 C<run>

  $conn->run(ping => sub { $_->do($query) });

简单的执行这个块的代码, 设置 C<$_> 为数据库的句柄. 根据不同的环境返回块的值为标量或者数组.

有个可选的第一个参数, 就是设置连接的模式, 这会覆盖原来的设置. 这可以选择的参数有  C<ping>, C<fixup>, 或 C<no_ping>(默认) 中任何一个.

为了方便, 你也可以嵌套调用到 C<run()> (or C<txn()> or C<svp()>), 这样连接模式用于检查连接的调用只会在最外层的块中调用并执行.

  $conn->txn(fixup => sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
      $conn->run(sub {
          $_->do($expensive_query);
          $conn->txn(sub {
              $_->do($another_expensive_query);
          });
      });
  });

顶层调用 C<txn()> 会给所有执行的代码都放到一个事务中执行. 如果你想使用子事务, 你可以使用 L<C<svp()>|/svp>  的调用.

如果你的代码块要做大量非数据库的操作, 你最好从 C<dbh()> 中来取得句柄:

  $conn->run(ping => sub {
      parse_gigabytes_of_xml(); # Get this out of the transaction!
      $conn->dbh->do($query);
  });

因为 C<dbh()> 会更加好的保证数据库句柄是活着的并且保证 C<fork> 和线程安全. 尽管它在 C<run()>, C<txn()> or C<svp()> 内部调用的时候并不会 C<ping()> 数据库.

=head3 C<txn>

  my $sth = $conn->txn(fixup => sub { $_->do($query) });

Starts a transaction, executes the block, setting C<$_> to and passing in the
database handle, and commits the transaction. If the block throws an
exception, the transaction will be rolled back and the exception re-thrown.
Returns the value returned by the block in scalar or array context as
appropriate (and the block can use C<wantarray> to decide what to do).

An optional first argument sets the connection mode, overriding that set in
the C<mode()> accessor, and may be one of C<ping>, C<fixup>, or C<no_ping>
(the default). In the case of C<fixup> mode, this means that the transaction
block will be re-executed for a new connection if the database handle is no
longer connected. In such a case, a second exception from the code block will
cause the transaction to be rolled back and the exception re-thrown. See
L</"Connection Modes"> for further explication.

As with C<run()>, calls to C<txn()> can be nested, although the connection
mode will be invoked to check the connection (or not) only in the outer-most
block method call. It's preferable to use C<dbh()> to fetch the database
handle from within the block if your code is doing lots of non-database
processing.

=head3 C<svp>

Executes a code block within the scope of a database savepoint if your
database supports them. Returns the value returned by the block in scalar or
array context as appropriate (and the block can use C<wantarray> to decide
what to do).

You can think of savepoints as a kind of subtransaction. What this means is
that you can nest your savepoints and recover from failures deeper in the nest
without throwing out all changes higher up in the nest. For example:

  $conn->txn(fixup => sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (1)');
      eval {
          $conn->svp(sub {
              shift->do('INSERT INTO table1 VALUES (2)');
              die 'OMGWTF?';
          });
      };
      warn "Savepoint failed\n" if $@;
      $dbh->do('INSERT INTO table1 VALUES (3)');
  });

This transaction will insert the values 1 and 3, but not 2.

  $conn->svp(fixup => sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (4)');
      $conn->svp(sub {
          shift->do('INSERT INTO table1 VALUES (5)');
      });
  });

This transaction will insert both 4 and 5.

Superficially, C<svp()> resembles L<C<run()>|/"run"> and L<C<txn()>|/"txn">,
including its support for the optional L<connection mode|/"Connection Modes">
argument, but in fact savepoints can only be used within the scope of a
transaction. Thus C<svp()> will start a transaction for you if it's called
without a transaction in-progress. It simply redispatches to C<txn()> with the
appropriate connection mode. Thus, this call from outside of a transaction:

  $conn->svp(ping => sub {
      $conn->svp( sub { ... } );
  });

Is equivalent to:

  $conn->txn(ping => sub {
      $conn->svp( sub { ... } );
  })

Savepoints are supported by the following RDBMSs:

=over

=item * PostgreSQL 8.0

=item * SQLite 3.6.8

=item * MySQL 5.0.3 (InnoDB)

=item * Oracle

=item * Microsoft SQL Server

=back

For all other RDBMSs, C<svp()> works just like C<txn()>: savepoints will be
ignored and the outer-most transaction will be the only transaction. This
tends to degrade well for non-savepoint-supporting databases, doing the right
thing in most cases.

=head3 C<mode>

  my $mode = $conn->mode;
  $conn->mode('fixup');
  $conn->txn(sub { ... }); # uses fixup mode.
  $conn->mode($mode);

Gets and sets the L<connection mode|/"Connection Modes"> attribute, which is
used by C<run()>, C<txn()>, and C<svp()> if no mode is passed to them.
Defaults to "no_ping". Note that inside a block passed to C<run()>, C<txn()>,
or C<svp()>, the mode attribute will be set to the optional first parameter:

  $conn->mode('ping');
  $conn->txn(fixup => sub {
      say $conn->mode; # Outputs "fixup"
  });
  say $conn->mode; # Outputs "ping"

In this way, you can reliably tell in what mode the code block is executing.

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if currently connected to the database and false if it's not. You
probably won't need to bother with this method; DBIx::Connector uses it
internally to determine whether or not to create a new connection to the
database before returning a handle from C<dbh()>.

=head3 C<in_txn>

  if ( $conn->in_txn ) {
     say 'Transacting!';
  }

Returns true if the connection is in a transaction. For example, inside a
C<txn()> block it would return true. It will also work if you use the DBI API
to manage transactions (i.e., C<begin_work()> or C<AutoCommit>.

Essentially, this is just sugar for:

  $con->run( no_ping => sub { !$_->{AutoCommit} } );

But without the overhead of the code reference or connection checking.

=head3 C<disconnect_on_destroy>

  $conn->disconnect_on_destroy(0);

By default, DBIx::Connector calls C<< $dbh->disconnect >> when it goes out of
scope and is garbage-collected by the system (that is, in its C<DESTROY()>
method). Usually this is what you want, but in some cases it might not be. For
example, you might have a module that uses DBIx::Connector internally, but
then makes the database handle available to callers, even after the
DBIx::Connector object goes out of scope. In such a case, you don't want the
database handle to be disconnected when the DBIx::Connector goes out of scope.
So pass a false value to C<disconnect_on_destroy> to prevent the disconnect.
An example:

  sub database_handle {
       my $conn = DBIx::Connector->new(@_);
       $conn->run(sub {
           # Do stuff here.
       });
       $conn->disconnect_on_destroy(0);
       return $conn->dbh;
  }

Of course, if you don't need to do any work with the database handle before
returning it to your caller, you can just use C<connect()>:

  sub database_handle {
      DBIx::Connector->connect(@_);
  }

=head3 C<disconnect>

  $conn->disconnect;

Disconnects from the database. Unless C<disconnect_on_destroy()> has been
passed a false value, DBIx::Connector uses this method internally in its
C<DESTROY> method to make sure that things are kept tidy.

=head3 C<driver>

  $conn->driver->begin_work( $conn->dbh );

In order to support all database features in a database-neutral way,
DBIx::Connector provides a number of different database drivers, subclasses of
L<DBIx::Connector::Driver>, that offer methods to handle database
communications. Although the L<DBI> provides a standard interface, for better
or for worse, not all of the drivers implement them, and some have bugs. To
avoid those issues, all database communications are handled by these driver
objects.

This can be useful if you want more fine-grained control of your
transactionality. For example, to create your own savepoint within a
transaction, you might do something like this:

  use Try::Tiny;
  my $driver = $conn->driver;
  $conn->txn(sub {
      my $dbh = shift;
      try {
          $driver->savepoint($dbh, 'mysavepoint');
          # do stuff ...
          $driver->release('mysavepoint');
      } catch {
          $driver->rollback_to($dbh, 'mysavepoint');
      };
  });

Most often you should be able to get what you need out of L<C<txn()>|/"txn">
and L<C<svp()>|/"svp">, but sometimes you just need the finer control. In
those cases, take advantage of the driver object to keep your use of the API
universal across database back-ends.

=head1 See Also

=over

=item * L<DBIx::Connector::Driver>

=item * L<DBI>

=item * L<DBIx::Class>

=item * L<Catalyst::Model::DBI>

=back

=head1 Support

This module is managed in an open
L<GitHub repository|http://github.com/theory/dbix-connector/>. Feel free to
fork and contribute, or to clone L<git://github.com/theory/dbix-connector.git>
and send patches!

Found a bug? Please L<post|http://github.com/theory/dbix-connector/issues> or
L<email|mailto:bug-dbix-connector@rt.cpan.org> a report!

=head1 Authors

This module was written and is maintained by:

=over

=item *

David E. Wheeler <david@kineticode.com>

=back

It is based on documentation, ideas, kibbitzing, and code from:

=over

=item * Tim Bunce <http://tim.bunce.name>

=item * Brandon L. Black <blblack@gmail.com>

=item * Matt S. Trout <mst@shadowcat.co.uk>

=item * Peter Rabbitson <ribasushi@cpan.org>

=item * Ash Berlin <ash@cpan.org>

=item * Rob Kinyon <rkinyon@cpan.org>

=item * Cory G Watson <gphat@cpan.org>

=item * Anders Nor Berle <berle@cpan.org>

=item * John Siracusa <siracusa@gmail.com>

=item * Alex Pavlovic <alex.pavlovic@taskforce-1.com>

=item * Many other L<DBIx::Class contributors|DBIx::Class/CONTRIBUTORS>

=back

=head1 Copyright and License

Copyright (c) 2009-2010 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
