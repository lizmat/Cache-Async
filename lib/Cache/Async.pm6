unit class Cache::Async;

=begin pod

=TITLE Cache::Async -- A Concurrent and Asynchronous Cache for Perl 6

This module tries to implement a cache that can be used easily in otherwise 
async or reactive system. As such it only returns Promises to results which 
can then be composed with other promises, or acted on directly. 

It tries to be a 'transparent' cache in the sense that it will return a 
cached item, or a freshly produced or retrieved one without the caller being
aware of the distinction. To do this, the cache is constructed over a producer
sub that gets called on cache misses. 

Sometimes other data that is required by the producer function can be captured 
at creation time, but in other cases they need to be provided at request time,
e.g. credentials. Arguments like these can be passed through Cache::Async 
transparently as extra args.

All caches should have a fixed size limit, and so does Cache::Async of course. 
In addition a maximum global object lifetime can be specified to avoid overly
old object entries. For cache eviction a LRU mechanism is used.

If caches are used in production systems, it is often desirable to monitor their
hit rates. Cache::Async supports this through a method that reports hits and 
misses, but it does not do the monitoring itself or automatically. 

=head1 Constructor

    new(:&producer, Int :$max-size, Duration :$max-age)

Creates a new cache over the provided B<&producer> sub, which must take a single
String as the first argument, the key used to look up items in the cache. It can take
more arguments, see B<get()> below.

The B<$max-size> argument can be used to limit the number of items the cache will hold at
any time, the default is 1024. 

B<$max-age> determines the maximum age an item can live in the cache before 
it is expired. By default items are not expired by age.

The following example will create a simple cache with up to 100 items that 
live for up to 10 seconds. The values returned by the cache are promises 
that will hold the key specified when querying the cache enclosed in square 
brackets.

   $cache = Cache::Async.new(producer => sub ($k) { return "[$k]"; }, 
                             max-size => 100,
                             max-age => Duration.new(10));

=end pod

my class Entry {
    has Str $.key;
    has $.value is rw;
    has $.timestamp is rw; # XXX would like this to be Instant but then it can't be nullable
    has Entry $.older is rw;
    has Entry $.younger is rw;
    has Promise $.promise is rw;
}

has &.producer;
has Int $.max-size = 1024;
has Duration $.max-age;

has Entry %!entries = {};
has Entry $!youngest;
has Entry $!oldest;
has Lock $!lock = Lock.new;

has atomicint $!hits = 0;
has atomicint $!misses = 0;

method !unlink($entry) {
    if $!youngest === $entry {
        $!youngest = $entry.older;
    }
    if $!oldest === $entry {
        $!oldest = $entry.younger;
    }
    if defined $entry.older {
        $entry.older.younger = $entry.younger;
        $entry.older = Nil;
    }
    if defined $entry.younger {
        $entry.younger.older = $entry.older;
        $entry.younger = Nil;
    }
}

method !link($entry) {
    if defined $!youngest {
        $!youngest.younger = $entry;
    }
    $entry.older = $!youngest;
    $!youngest = $entry;
    if ! defined $!oldest {
        $!oldest = $entry;
    }
}

method !expire-by-count() {
    while (%!entries.elems > $!max-size) {
        my $evicted = $!oldest;
        my $key = $evicted.key;
        %!entries{$evicted.key}:delete;
        self!unlink($evicted);
    }
}

method !expire-by-age($now) {
    while (defined $!oldest) && ($!oldest.timestamp < ($now - $!max-age)) {
        # XXX duplication from above
        my $evicted = $!oldest;
        my $key = $evicted.key;
        %!entries{$evicted.key}:delete;
        self!unlink($evicted);
    }
}

=begin pod
=head1 Retrieval

In order to get items from, or better through, the cache, the B<get()> method is used:

    get($key, +@args --> Promise) {

The first argument is the B<$key> used to look up items in the cache, and is passed 
through to the producer function the cache uses. Any other arguments are also passed 
to the producer functions. The call returns a promise to the value produced or found 
in the cache.

With the cache constructed above, the call below would yield "[woot]". The first time
this is called the producer is called, afterwards the cached value is used (until 
expiry or eviction).

    await $cache.get('woot')

Multiple threads can of course safely call into the cache in parallel.

The producer function can of course return a promise itself! In this case Cache::Async 
will I<not> return a promise containing another promise, but it will detect the case 
and simply return the promise from the producer directly. 

=end pod

method get($key, +@args --> Promise) {
    my $entry;
    my $now = Nil;
    $!lock.protect({
        if defined $!max-age {
            $now = now;
            self!expire-by-age($now);
        }
        $entry = %!entries{$key};
        if ! defined $entry {
            atomic-inc-fetch($!misses);
            $entry = Entry.new(key => $key, timestamp => $now);
            %!entries{$key} = $entry;
            self!link($entry);            
            $entry.promise = Promise.new;
            my $producer-promise = Promise.start({
                my $prod-result = &.producer.($key, |@args);
                CATCH {
                    default: $entry.promise.break($_);
                }
                $!lock.protect({
                    if $prod-result.isa(Promise) {
                        $prod-result.then(-> $value {
                            $!lock.protect({
                                if ($value.status ~~ Kept) {
                                    $entry.value = $value.result;
                                    $entry.promise.keep($value.result);
                                    $entry.promise = Nil;
                                }
                                else {
                                    $entry.promise.break($value.cause);
                                    $entry.promise = Nil;
                                }
                            });
                        });
                    }
                    else {
                        $entry.value = $prod-result;
                        $entry.promise.keep($prod-result);
                        $entry.promise = Nil;
                    }
                });
            });
            self!expire-by-count();
            return $entry.promise;
        }
        else {
            if defined $entry.promise {
                atomic-inc-fetch($!misses);
                return $entry.promise;
            }
            else {
                atomic-inc-fetch($!hits);
                my $ret = Promise.new;
                $ret.keep($entry.value);
                return $ret;
            }
        }
    });
}

=begin pod
=head1 Cache Content Management

The following methods can be used to manage the contents of the cache. This 
can for example be used to warm the cache on startup with some values, or 
clear it in error cases.

    put($key, $value)
    remove($key)
    clear()

=end pod

method put($key, $value) {
    $!lock.protect({
        my $entry = %!entries{$key};
        if ! defined $entry {
            $entry = Entry.new(key => $key, value => $value);
            %!entries{$key} = $entry;
        }
        $entry.value = $value;
        self!expire-by-count();
    });
}

method remove($key) {
    $!lock.protect({
        my $removed = %!entries{$key};
        if defined $removed {
            self!unlink($removed);
        }
        %!entries{$key}:delete;
    });
}

method clear() {
    $!lock.protect({
        %!entries = %();
        $!youngest = Nil;
        $!oldest = Nil;
    });
}

=begin pod
=head1 Monitoring

The behavior of the cache can be monitored, the call will return total 
numbers since the last time this method was called (or the cache got 
constructed):

    my ($hits, $misses) = $cache.hits-misses;

Note that the number of hits + misses is of course the number of calls to 
B<get()>, but that the number of calls to the producer function is not 
necessarily the same as the number of misses returned from this method. The
reason for this is that two calls to the cache with the same key in rapid 
succession could both be misses, but only the first one will call the 
producer. The second call will simply get chained to the first producer 
call.

=end pod

method hits-misses() {
    my $current-hits = atomic-fetch($!hits);
    my $current-misses = atomic-fetch($!misses);
    atomic-fetch-sub($!hits, $current-hits);
    atomic-fetch-sub($!misses, $current-misses);
    return ($current-hits, $current-misses);
}
