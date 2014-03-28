Db = require('mongodb').Db
GridStore = require('mongodb').GridStore
Server = require('mongodb').Server
ObjectID = require('mongodb').ObjectID
assert = require('assert')
Lock = require('./index').Lock
LockCollection = require('./index').LockCollection

chunkSize = 256*1024;  # Standard 256KB chunks

myTimeout = (t, cb) ->
  setTimeout cb, t

db = new Db('test', new Server('127.0.0.1', 27017), {w: 1})
# Establish connection to db
db.open (err, db) ->
  # Our file ID
  # fileId = new ObjectID()
  fileId = "Thatfile"
  vc = db.collection('fs.files')
  vc.insert { _id: fileId, value: 0}, (err, doc) ->

    counter = 1
    done = 0
    read_failed = 0
    read_nolock = 0
    read_waiting = 0
    write_failed = 0
    write_nolock = 0
    write_waiting = 0
    max = 10000
    fail_rate = 0.1
    locks = []

    closeUp = () ->
      if done+read_failed+write_failed+write_nolock+read_nolock is max-1
        console.log "All work complete, closing!\n Done: #{done} read fail: #{read_failed} read no lock: #{read_nolock} write fail: #{write_failed} write no lock #{write_nolock}"
        db.close()

    LockCollection.create db, "fs", { lockExpiration: 15, pollingInterval: 1 }, (err, lockColl) ->
      throw err if (err)

      spawner = () ->
        if counter < max
          c = counter
          locks[c] = Lock(fileId, lockColl, { timeOut: 30 })
          fail = false
          if (Math.random() <= 0.01)
            fail = Math.random() < fail_rate
            write_waiting++
            # console.log "Write lock #{c}"
            locks[c].obtainWriteLock (err, res) ->
              throw err if err
              write_waiting--
              if res and not fail
                vc.update {_id: fileId }, { $inc: { value: 0.5 } }, (err, doc) ->
                  myTimeout Math.floor(Math.random()*250), () ->
                    vc.update {_id: fileId }, { $inc: { value: 0.5 } }, (err, doc) ->
                      locks[c].releaseLock (err, res) ->
                        throw err if err
                        console.log "Value updated. #{c} #{res.reads} #{res.writes} #{res.read_locks} #{res.write_request} #{read_waiting} #{write_waiting}"
                        done++
                        # console.log "Done: #{done}"
                        closeUp()
              else
                if fail
                  console.log "#### Write lock failure #{c}"
                  write_failed++
                else
                  write_nolock++
                closeUp()
          else
            read_waiting++
            # console.log "Read lock #{c}"
            locks[c].obtainReadLock (err, res) ->
              throw err if err
              read_waiting--
              if res and not fail
                myTimeout Math.floor(Math.random()*250), () ->
                  vc.findOne {_id: fileId }, (err, doc) ->
                    locks[c].releaseLock (err, res) ->
                      throw err if err
                      console.log "Value : #{c} #{res.reads} #{res.writes} #{doc.value} #{res.read_locks} #{res.write_request} #{read_waiting} #{write_waiting}"
                      done++
                      # console.log "Done: #{done}"
                      closeUp()
              else
                if fail
                  read_failed++
                  console.log "#### Read lock failure #{c}"
                else
                  read_nolock++
                closeUp()

          counter++
          myTimeout Math.floor(Math.random()*200), spawner

      spawner()
