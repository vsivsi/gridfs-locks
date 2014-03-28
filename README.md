# gridfs-locks

 `gridfs-locks` implements distributed and [fair read/write locking](https://en.wikipedia.org/wiki/Readers-writer_lock) based on [MongoDB](http://www.mongodb.org/), and is specifically designed to make MongoDB's [GridFS](http://docs.mongodb.org/manual/reference/gridfs/) file-store safe for concurrent access. It is a [node.js](http://nodejs.org/) [npm package](https://www.npmjs.org/) built on top of the [native `mongodb` driver](https://www.npmjs.org/package/mongodb), and is compatible with the native [GridStore](https://github.com/mongodb/node-mongodb-native/blob/master/docs/gridfs.md) implementation.

## Why?

I know what you're thinking:
-   why does there need to be yet another locking library for node?
-   why not do this using [Redis](http://redis.io/), or better yet use one of the [existing Redis solutions](https://github.com/search?q=redis+locks&search_target=global)?
-   wait, safe concurrent access [isn't baked into MongoDB GridFS](https://jira.mongodb.org/browse/NODE-157)?

I'll answer these in reverse order... GridFS is MongoDB's file store technology; really it's just a bunch of "data model" conventions making it possible to store binary blobs of arbitrarily large non-JSON data in MongoDB collections. And it's totally useful.

However, the GridFS data model says nothing about how to safely synchronize attempted concurrent read/write access to stored files. This is a problem because GridFS uses two separate collections to store file metadata and data chunks, respectively. And since [MongoDB has no native support for atomic multi-operation transactions](http://docs.mongodb.org/manual/tutorial/isolate-sequence-of-operations/), this turns out to be a critical omission for almost any real-world use of GridFS.

The official node.js native mongo driver's [GridStore](https://github.com/mongodb/node-mongodb-native/blob/master/docs/gridfs.md) library is only "safe" (won't throw errors and/or corrupt GridFS data files) under two possible scenarios:

1.   Once created, files are strictly read-only. After the initial write, they can never be changed or deleted.
2.   The application **never** attempts concurrent accesses to a given file.

Neither of these constraints is acceptable for most real applications likely to be built with node.js using MongoDB. The solution is an efficient and robust locking mechanism to properly synchronize read/write accesses to GridFS files, which is what this package provides.

[Redis](http://redis.io/) is an amazing tool and this task could be certainly be done using Redis, but in this case we are already using MongoDB and it also has the capability to get the job done, so adding an unnecessary dependency on another server technology is undesirable.

I tailored this library to use MongoDB and mirror the GridFS data model in the hopes that it may inspire the MongoDB team to add official concurrency features to a future version of the GridFS specification. In the meantime, this library will hopefully suffice in making GridFS generally useful for real world applications. I welcome all feedback.

### Installation

Requires node.js, npm, and uses the native node.js mongo driver.

    npm install gridfs-locks

## Use

```js
var Db = require('mongodb').Db;
var Server = require('mongodb').Server;
var db = new Db('test', new Server('127.0.0.1', 27017));
var LockCollection = require('grid-locks').LockCollection
var Lock = require('grid-locks').Lock

// Open the database
db.open(function(err, db) {

  // Setup GridStore, etc.

  // Create a lock collection alongside the GridFS collections
  LockCollection.create(db, 'fs', {}, function (err, lockColl) {

    var ID = something;  // ID is the unique _id of a GridFS file, or whatever...

    // Create a lock object for ID
    var lock = new Lock(ID, lockColl, {});

    // Request a write lock
    lock.obtainWriteLock(function(err, res) {
      if (err || res == null) {
        // Error or didn't get the lock...
      }

      // Write to a gridFS file, do generally unsafe things

      // Don't forget!
      lock.releaseLock(function (err, res) {});

    });

    // Another lock on same resource ID
    var lock2 = new Lock(ID, lockColl, {});

    // Request a read lock
    lock2.obtainReadLock(function(err, res) {
      if (err || res == null) {
        // Error or didn't get the lock...
      }

      // Read from a GridFS file, safe in the knowledge that some
      // concurrent writer isn't going to make you crash...

      // Don't forget!
      lock.releaseLock(function (err, res) {});

    });
  });
});
```

## How it works (briefly)

GridFS itself creates [two collections](http://docs.mongodb.org/manual/reference/gridfs/) based off a root name (default root is `fs`) called e.g. `fs.files` and `fs.chunks`. `gridfs-locks` takes the same root name and creates a third collection (e.g. `fs.locks`) that contains documents used to provide robust locking. Internally, it uses the [MongoDB `findAndModify()` operation](http://docs.mongodb.org/manual/reference/method/db.collection.findAndModify/) to guarantee the atomicity of lock updates. `gridfs-locks` does not touch or even know about the `.files` and `.chunks` collections, and so it doesn't interfere with (or even require) a GridFS store to work. As an aside, for this reason it is completely general and can be used as distributed locking scheme for any purpose, not just for making GridFS concurrency-safe.

gridfs-locks uses a [multiple-reader/exclusive-writer model for locking, with a fair write-request scheme](https://en.wikipedia.org/wiki/Readers-writer_lock) to prevent blocking of writes by a continuous stream of readers. There is optional support for lock expiration, attaching metadata to locks (for debugging distributed applications), and waiting to obtain locks with timeout. When waiting for locks, the polling interval is also configurable. All of the above options can be configured globally, or on a per-lock basis. As a bonus, `gridfs-locks` also tracks the number of successful read and write locks granted for each resource.

As with any locking scheme, care must be taken to avoid creating [deadlocks](https://en.wikipedia.org/wiki/Deadlocks), and the built-in lock expiration pattern may be helpful in doing so. Note that the default configuration is that locks never expire, and attempts to obtain unavailable locks return immediately without a valid lock. These behaviors may be changed using the `lockExpiration`, `timeOut` and `pollingInterval` options.

## API

### LockCollection.create()

Create a new lock collection. **Note**: Do not use `new LockCollection()` because collection creation needs an async callback.

```js
LockCollection.create(
  db,      // Must be an open mongodb connection object
  'fs',    // Root name for the collection. Will become "fs.locks"
  {                       // Options: All can be overridden per lock.
    lockExpiration: 300,  // seconds until a lock expires in the database  Default: Never expire
    timeOut: 30,          // seconds to poll when obtaining a lock that is not available.  Default: Do not poll
    pollingInterval: 5,   // seconds between successive attempts to acquire a lock while waiting  Default: 5 sec
    metaData:             // metadata to store in the lock documents, useful for debugging  Default: null
    w: 1                  // mongodb write-concern  Default: 1
  },
  function (err, lockColl) {
    // err:       any database errors or problems with parameters
    // lockColl:  a LockCollection object if successful
  }
);
```

### Lock()

Create a new Lock object. Lock objects may be reused, but are tied to a single Id for their lifetime.

```js
lock = new Lock(
  Id,         // Unique identifier for resource being locked. Type must be compatible with mongodb `_id`
  lockColl,   // A valid LockCollection object
  {                       // Options:
    lockExpiration: 300,  // seconds until a lock expires in the database  Default: Never expire
    timeOut: 30,          // seconds to poll when obtaining a lock that is not available.  Default: Do not poll
    pollingInterval: 5,   // seconds between successive attempts to acquire a lock while waiting  Default: 5 sec
    metaData:             // metadata to store in the lock document, useful for debugging  Default: null
  }
);

```

### lock.obtainReadLock()

Attempt to obtain a non-exclusive lock on the resource. There can be multiple simultaneous readers of a resource.

```js
lock.obtainReadLock(
  function (err, l) {
    // err:   any database error
    // l:     the lock document obtained. If null, the attempt failed or timed out
  }
);
```

### lock.obtainWriteLock()

Attempt to obtain an exclusive lock on the resource. When a write lock is obtained, there can be no other readers or writers.

```js
lock.obtainReadLock(
  function (err, l) {
    // err:   any database error
    // l:     the lock document obtained. If null, the attempt failed or timed out
  }
);
```

### lock.releaseLock()

Release a held lock, either read or write

```js
lock.releaseLock(
  function (err, l) {
    // err:   any database errors or lock document not found
    // l:     the freed lock document
  }
);
```

### lock.renewLock()

Reset the lock expiration time to `lockExpiration` seconds from now.

```js
lock.renewLock(
  function (err, l) {
    // err:   any database error or lock document not found
    // l:     the lock document obtained.
  }
);
```

## Lock Document Data Model
```js
{
  files_id: Id,             // The id of the resource being locked
  expires: lockExpireTime,  // Date(), when this lock will expire
  read_locks: 0,            // Number of current read locks granted
  write_lock: false,        // Is there currently a write lock granted?
  write_req: false,         // Are there one or more write requests?
  reads: 0,                 // Successful read counter
  writes: 0,                // Successful write counter
  meta: null                // Application metadata
}
```



