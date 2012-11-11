package DBIx::Class::Relationship;

use strict;
use warnings;

use base qw/DBIx::Class/;

__PACKAGE__->load_own_components(qw/
  Helpers
  Accessor
  CascadeActions
  ProxyMethods
  Base
/);

=head1 NAME

DBIx::Class::Relationship - Inter-table relationships

=head1 SYNOPSIS

  ## Creating relationships
  MyDB::Schema::Actor->has_many('actorroles' => 'MyDB::Schema::ActorRole',
                                'actor');
  MyDB::Schema::Role->has_many('actorroles' => 'MyDB::Schema::ActorRole',
                                'role');
  MyDB::Schema::ActorRole->belongs_to('role' => 'MyDB::Schema::Role');
  MyDB::Schema::ActorRole->belongs_to('actor' => 'MyDB::Schema::Actor');

  MyDB::Schema::Role->many_to_many('actors' => 'actorroles', 'actor');
  MyDB::Schema::Actor->many_to_many('roles' => 'actorroles', 'role');

  ## Using relationships
  $schema->resultset('Actor')->find({ id => 1})->roles();
  $schema->resultset('Role')->find({ id => 1 })->actorroles->search_related('actor', { Name => 'Fred' });
  $schema->resultset('Actor')->add_to_roles({ Name => 'Sherlock Holmes'});

See L<DBIx::Class::Manual::Cookbook> for more.

=head1 描述

在 DBIx::Class 中 I<Relationship> 这个词有特定的含义。可以看  L<Glossary|DBIx::Class::Manual::Glossary/Relationship>.

这个类提供了方法来设置您的数据库模型中的表之间的关系。 关系是 L<DBIx::Class> 提供的最有用和强大的技术。
要建立有效的数据库查询，在创建后有共同的东西，例如，如果你有一个 authors 表和其它所有表之间的关系：

  ID  | Name | Age
 ------------------
   1  | Fred | 30
   2  | Joe  | 32

和一个 Books 的表:

  ID  | Author | Name
 --------------------
   1  |      1 | Rulers of the universe
   2  |      1 | Rulers of the galaxy

如果是没有关系(Relationship),这时取得 Fred 的所有的书籍是这样的：

 my $fred = $schema->resultset('Author')->find({ Name => 'Fred' });
 my $fredsbooks = $schema->resultset('Book')->search({ Author => $fred->ID });

有一个 has_many 的关系就 "books" 的作者(见下文)。我们可以替换为这样操作:

 my $fredsbooks = $schema->resultset('Author')->find({ Name => 'Fred' })->books;

在 L<DBIx::Class::Manual::Glossary/"Row"> 中为每种不同的关系设置了访问器的方法。在  L<DBIx::Class::Manual::Glossary/"ResultSet">  的对象中，查找有关系的内容时，可以使用  "search_related" 的方法.
在列表上下文中，每个返回行对象相关的类的列表，在标量上下文中，一个新的 ResultSet 表示表的返回。
由于数据库是不实际的查询，直到您尝试检索一个实际项目的数据，所以不会有时间浪费在这个上面。

 my $cheapfredbooks = $schema->resultset('Author')->find({
   Name => 'Fred',
 })->books->search_related('prices', {
   Price => { '<=' => '5.00' },
 });

会产生一个查询的东西，如

 SELECT * FROM Author me
 LEFT JOIN Books books ON books.author = me.id
 LEFT JOIN Prices prices ON prices.book = books.id
 WHERE prices.Price <= 5.00

all without needing multiple fetches.

Only the helper methods for setting up standard relationship types
are documented here. For the basic, lower-level methods, and a description
of all the useful *_related methods that you get for free, see
L<DBIx::Class::Relationship::Base>.

=head1 METHODS

所有的 helper 方法类似下面的模板：

  __PACKAGE__->$method_name('relname', 'Foreign::Class', \%cond | \@cond, \%attrs);

在 C<$cond> 和 C<$attrs> 是可选的。 如果你想使用 C<\%attrs> 时可以直接给 C<$cond> 设置成 C<undef>.

见 L<DBIx::Class::Relationship::Base> 文档中有可以使用的属性的文档.


=head2 belongs_to

=over 4

=item 参数: $accessor_name, $related_class, $our_fk_column|\%cond|\@cond?, \%attrs?

=back

Creates a relationship where the calling class stores the foreign
class's primary key in one (or more) of the calling class columns.
This relationship defaults to using C<$accessor_name> as the column
name in this class to resolve the join against the primary key from
C<$related_class>, unless C<$our_fk_column> specifies the foreign key column
in this class or C<cond> specifies a reference to a join condition hash.

=over

=item accessor_name

This argument is the name of the method you can call on a L<DBIx::Class::Row> object to retrieve the instance of the foreign class matching this relationship. This is often called the C<relation(ship) name>.

Use this accessor_name in L<DBIx::Class::ResultSet/join>
or L<DBIx::Class::ResultSet/prefetch> to join to the foreign table
indicated by this relationship.

=item related_class

This is the class name of the table referenced by the foreign key in
this class.

=item our_fk_column

The column name on this class that contains the foreign key.

OR

=item cond

A hashref where the keys are C<foreign.$column_on_related_table> and
the values are C<self.$our_fk_column>. This is useful for
relations that are across multiple columns.

=back


  # in a Book class (where Author has many Books)
  My::DBIC::Schema::Book->belongs_to( 
    author => 
    'My::DBIC::Schema::Author', 
    'author_id'
  );

  # OR (same result)
  My::DBIC::Schema::Book->belongs_to(
    author =>
    'My::DBIC::Schema::Author',
    { 'foreign.author_id' => 'self.author_id' } 
  );

  # OR (similar result but uglier accessor name)
  My::DBIC::Schema::Book->belongs_to( 
    author_id =>
    'My::DBIC::Schema::Author'
  );

  # Usage
  my $author_obj = $book->author; # get author object
  $book->author( $new_author_obj ); # set author object
  $book->author_id(); # get the plain id

  # To retrieve the plain id if you used the ugly version:
  $book->get_column('author_id');


If the relationship is optional -- i.e. the column containing the foreign key
can be NULL -- then the belongs_to relationship does the right thing. Thus, in
the example above C<$obj-E<gt>author> would return C<undef>.  However in this
case you would probably want to set the C<join_type> attribute so that a C<LEFT
JOIN> is done, which makes complex resultsets involving C<join> or C<prefetch>
operations work correctly.  The modified declaration is shown below:

  # in a Book class (where Author has_many Books)
  __PACKAGE__->belongs_to(
    author => 
    'My::DBIC::Schema::Author',
    'author', 
    { join_type => 'left' }
  );


Cascading deletes are off by default on a C<belongs_to>
relationship. To turn them on, pass C<< cascade_delete => 1 >>
in the $attr hashref.

By default, DBIC will return undef and avoid querying the database if a
C<belongs_to> accessor is called when any part of the foreign key IS NULL. To
disable this behavior, pass C<< undef_on_null_fk => 0 >> in the C<$attr>
hashref.

NOTE: If you are used to L<Class::DBI> relationships, this is the equivalent
of C<has_a>.

See L<DBIx::Class::Relationship::Base> for documentation on relationship
methods and valid relationship attributes. Also see L<DBIx::Class::ResultSet>
for a L<list of standard resultset attributes|DBIx::Class::ResultSet/ATTRIBUTES>
which can be assigned to relationships as well.

=head2 has_many

=over 4

=item 参数: $accessor_name, $related_class, $their_fk_column|\%cond|\@cond?, \%attrs?

=back

对当前这个类的主键，在外部类上创建一个一对多的关系。这个关系是指零个或多个在外部表中的记录(例如: C<LEFT JOIN>);
Creates a one-to-many relationship where the foreign class refers to this class's primary key. This relationship refers to zero or more records in the foreign table (e.g. a C<LEFT JOIN>). This relationship defaults to using the end of this classes namespace as the foreign key in C<$related_class> to resolve the join, unless C<$their_fk_column> specifies the foreign key column in C<$related_class> or C<cond> specifies a reference to a join condition hash.

=over

=item accessor_name

This argument is the name of the method you can call on a
L<DBIx::Class::Row> object to retrieve a resultset of the related
class restricted to the ones related to the row object. In list
context it returns the row objects. This is often called the
C<relation(ship) name>.

Use this accessor_name in L<DBIx::Class::ResultSet/join>
or L<DBIx::Class::ResultSet/prefetch> to join to the foreign table
indicated by this relationship.

=item related_class

This is the class name of the table which contains a foreign key
column containing PK values of this class.

=item their_fk_column

相关的类(related class)上包含外键的列的名字

OR

=item cond

A hashref where the keys are C<foreign.$their_fk_column> and
the values are C<self.$matching_column>. This is useful for
relations that are across multiple columns.

OR

An arrayref containing an SQL::Abstract-like condition. For example a
link table where two columns link back to the same table. This is an
OR condition.

  My::Schema::Item->has_many('rels', 'My::Schema::Relationships',
                             [ { 'foreign.LItemID' => 'self.ID' },
                               { 'foreign.RItemID' => 'self.ID'} ]);

=back

  # in an Author class (where Author has_many Books)
  # assuming related class is storing our PK in "author_id"
  My::DBIC::Schema::Author->has_many(
    books => 
    'My::DBIC::Schema::Book', 
    'author_id'
  );

  # OR (same result)
  My::DBIC::Schema::Author->has_many(
    books => 
    'My::DBIC::Schema::Book', 
    { 'foreign.author_id' => 'self.id' },
  );

  # OR (similar result, assuming related_class is storing our PK, in "author")
  # (the "author" is guessed at from "Author" in the class namespace)
  My::DBIC::Schema::Author->has_many(
    books => 
    'My::DBIC::Schema::Book', 
  );


  # Usage
  # resultset of Books belonging to author 
  my $booklist = $author->books;

  # resultset of Books belonging to author, restricted by author name
  my $booklist = $author->books({
    name => { LIKE => '%macaroni%' },
    { prefetch => [qw/book/],
  });

  # array of Book objects belonging to author
  my @book_objs = $author->books;

  # force resultset even in list context
  my $books_rs = $author->books;
  ( $books_rs ) = $obj->books_rs;

  # create a new book for this author, the relation fields are auto-filled
  $author->create_related('books', \%col_data);
  # alternative method for the above
  $author->add_to_books(\%col_data);


Three methods are created when you create a has_many relationship.  The first
method is the expected accessor method, C<$accessor_name()>.  The second is
almost exactly the same as the accessor method but "_rs" is added to the end of
the method name.  This method works just like the normal accessor, except that
it always returns a resultset, even in list context. The third method,
named C<< add_to_$relname >>, will also be added to your Row items; this
allows you to insert new related items, using the same mechanism as in
L<DBIx::Class::Relationship::Base/"create_related">.

If you delete an object in a class with a C<has_many> relationship, all
the related objects will be deleted as well.  To turn this behaviour off,
pass C<< cascade_delete => 0 >> in the C<$attr> hashref.

The cascaded operations are performed after the requested delete or
update, so if your database has a constraint on the relationship, it
will have deleted/updated the related records or raised an exception
before DBIx::Class gets to perform the cascaded operation.

If you copy an object in a class with a C<has_many> relationship, all
the related objects will be copied as well. To turn this behaviour off,
pass C<< cascade_copy => 0 >> in the C<$attr> hashref. The behaviour
defaults to C<< cascade_copy => 1 >>.

See L<DBIx::Class::Relationship::Base> for documentation on relationship
methods and valid relationship attributes. Also see L<DBIx::Class::ResultSet>
for a L<list of standard resultset attributes|DBIx::Class::ResultSet/ATTRIBUTES>
which can be assigned to relationships as well.

=head2 might_have

=over 4

=item Arguments: $accessor_name, $related_class, $their_fk_column|\%cond|\@cond?, \%attrs?

=back

Creates an optional one-to-one relationship with a class. This relationship
defaults to using C<$accessor_name> as the foreign key in C<$related_class> to
resolve the join, unless C<$their_fk_column> specifies the foreign key
column in C<$related_class> or C<cond> specifies a reference to a join
condition hash.

=over

=item accessor_name

This argument is the name of the method you can call on a
L<DBIx::Class::Row> object to retrieve the instance of the foreign
class matching this relationship. This is often called the
C<relation(ship) name>.

Use this accessor_name in L<DBIx::Class::ResultSet/join>
or L<DBIx::Class::ResultSet/prefetch> to join to the foreign table
indicated by this relationship.

=item related_class

This is the class name of the table which contains a foreign key
column containing PK values of this class.

=item their_fk_column

The column name on the related class that contains the foreign key.

OR

=item cond

A hashref where the keys are C<foreign.$their_fk_column> and
the values are C<self.$matching_column>. This is useful for
relations that are across multiple columns.

=back

  # Author may have an entry in the pseudonym table
  My::DBIC::Schema::Author->might_have(
    pseudonym =>
    'My::DBIC::Schema::Pseudonym',
    'author_id',
  );

  # OR (same result, assuming the related_class stores our PK)
  My::DBIC::Schema::Author->might_have(
    pseudonym =>
    'My::DBIC::Schema::Pseudonym',
  );

  # OR (same result)
  My::DBIC::Schema::Author->might_have(
    pseudonym =>
    'My::DBIC::Schema::Pseudonym',
    { 'foreign.author_id' => 'self.id' },
  );

  # Usage
  my $pname = $author->pseudonym; # to get the Pseudonym object

If you update or delete an object in a class with a C<might_have>
relationship, the related object will be updated or deleted as well. To
turn off this behavior, add C<< cascade_delete => 0 >> to the C<$attr>
hashref.

The cascaded operations are performed after the requested delete or
update, so if your database has a constraint on the relationship, it
will have deleted/updated the related records or raised an exception
before DBIx::Class gets to perform the cascaded operation.

See L<DBIx::Class::Relationship::Base> for documentation on relationship
methods and valid relationship attributes. Also see L<DBIx::Class::ResultSet>
for a L<list of standard resultset attributes|DBIx::Class::ResultSet/ATTRIBUTES>
which can be assigned to relationships as well.

Note that if you supply a condition on which to join, if the column in the
current table allows nulls (i.e., has the C<is_nullable> attribute set to a
true value), than C<might_have> will warn about this because it's naughty and
you shouldn't do that.  

 "might_have/has_one" must not be on columns with is_nullable set to true (MySchema::SomeClass/key)

If you must be naughty, you can suppress the warning by setting
C<DBIC_DONT_VALIDATE_RELS> environment variable to a true value.  Otherwise,
you probably just want to use C<DBIx::Class::Relationship/belongs_to>.

=head2 has_one

=over 4

=item Arguments: $accessor_name, $related_class, $their_fk_column|\%cond|\@cond?, \%attrs?

=back

Creates a one-to-one relationship with a class. This relationship
defaults to using C<$accessor_name> as the foreign key in C<$related_class> to
resolve the join, unless C<$their_fk_column> specifies the foreign key
column in C<$related_class> or C<cond> specifies a reference to a join
condition hash.

=over

=item accessor_name

This argument is the name of the method you can call on a
L<DBIx::Class::Row> object to retrieve the instance of the foreign
class matching this relationship. This is often called the
C<relation(ship) name>.

Use this accessor_name in L<DBIx::Class::ResultSet/join>
or L<DBIx::Class::ResultSet/prefetch> to join to the foreign table
indicated by this relationship.

=item related_class

This is the class name of the table which contains a foreign key
column containing PK values of this class.

=item their_fk_column

The column name on the related class that contains the foreign key.

OR

=item cond

A hashref where the keys are C<foreign.$their_fk_column> and
the values are C<self.$matching_column>. This is useful for
relations that are across multiple columns.

=back

  # Every book has exactly one ISBN
  My::DBIC::Schema::Book->has_one(
    isbn => 
    'My::DBIC::Schema::ISBN',
    'book_id',
  );

  # OR (same result, assuming related_class stores our PK)
  My::DBIC::Schema::Book->has_one(
    isbn => 
    'My::DBIC::Schema::ISBN',
  );

  # OR (same result)
  My::DBIC::Schema::Book->has_one(
    isbn => 
    'My::DBIC::Schema::ISBN',
    { 'foreign.book_id' => 'self.id' },
  );

  # Usage
  my $isbn_obj = $book->isbn; # to get the ISBN object

Creates a one-to-one relationship with another class. This is just
like C<might_have>, except the implication is that the other object is
always present. The only difference between C<has_one> and
C<might_have> is that C<has_one> uses an (ordinary) inner join,
whereas C<might_have> defaults to a left join.

The has_one relationship should be used when a row in the table has exactly one
related row in another table. If the related row might not exist in the foreign
table, use the L<DBIx::Class::Relationship/might_have> relationship.

In the above example, each Book in the database is associated with exactly one
ISBN object.

See L<DBIx::Class::Relationship::Base> for documentation on relationship
methods and valid relationship attributes. Also see L<DBIx::Class::ResultSet>
for a L<list of standard resultset attributes|DBIx::Class::ResultSet/ATTRIBUTES>
which can be assigned to relationships as well.

Note that if you supply a condition on which to join, if the column in the
current table allows nulls (i.e., has the C<is_nullable> attribute set to a
true value), than warnings might apply just as with
L<DBIx::Class::Relationship/might_have>.

=head2 many_to_many

=over 4

=item Arguments: $accessor_name, $link_rel_name, $foreign_rel_name, \%attrs?

=back

C<many_to_many> is a I<Relationship bridge> which has a specific
meaning in DBIx::Class, see the definition in the
L<Glossary|DBIx::Class::Manual::Glossary/Relationship bridge>.

C<many_to_many> is not strictly a relationship in its own right. Instead, it is
a bridge between two resultsets which provide the same kind of convenience
accessors as true relationships provide. Although the accessor will return a 
resultset or collection of objects just like has_many does, you cannot call 
C<related_resultset> and similar methods which operate on true relationships.

=over

=item accessor_name

This argument is the name of the method you can call on a
L<DBIx::Class::Row> object to retrieve the rows matching this
relationship.

On a many_to_many, unlike other relationships, this cannot be used in
L<DBIx::Class::ResultSet/search> to join tables. Use the relations
bridged across instead.

=item link_rel_name

This is the accessor_name from the has_many relationship we are
bridging from.

=item foreign_rel_name

This is the accessor_name of the belongs_to relationship in the link
table that we are bridging across (which gives us the table we are
bridging to).

=back

To create a many_to_many relationship from Actor to Role:

  My::DBIC::Schema::Actor->has_many( actor_roles =>
                                     'My::DBIC::Schema::ActorRoles',
                                     'actor' );
  My::DBIC::Schema::ActorRoles->belongs_to( role =>
                                            'My::DBIC::Schema::Role' );
  My::DBIC::Schema::ActorRoles->belongs_to( actor =>
                                            'My::DBIC::Schema::Actor' );

  My::DBIC::Schema::Actor->many_to_many( roles => 'actor_roles',
                                         'role' );

And, for the reverse relationship, from Role to Actor:

  My::DBIC::Schema::Role->has_many( actor_roles =>
                                    'My::DBIC::Schema::ActorRoles',
                                    'role' );

  My::DBIC::Schema::Role->many_to_many( actors => 'actor_roles', 'actor' );

To add a role for your actor, and fill in the year of the role in the
actor_roles table:

  $actor->add_to_roles($role, { year => 1995 });

In the above example, ActorRoles is the link table class, and Role is the
foreign class. The C<$link_rel_name> parameter is the name of the accessor for
the has_many relationship from this table to the link table, and the
C<$foreign_rel_name> parameter is the accessor for the belongs_to relationship
from the link table to the foreign table.

To use many_to_many, existing relationships from the original table to the link
table, and from the link table to the end table must already exist, these
relation names are then used in the many_to_many call.

In the above example, the Actor class will have 3 many_to_many accessor methods
set: C<roles>, C<add_to_roles>, C<set_roles>, and similarly named accessors
will be created for the Role class for the C<actors> many_to_many
relationship.

See L<DBIx::Class::Relationship::Base> for documentation on relationship
methods and valid relationship attributes. Also see L<DBIx::Class::ResultSet>
for a L<list of standard resultset attributes|DBIx::Class::ResultSet/ATTRIBUTES>
which can be assigned to relationships as well.

=cut

1;

=head1 AUTHORS

see L<DBIx::Class>

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

