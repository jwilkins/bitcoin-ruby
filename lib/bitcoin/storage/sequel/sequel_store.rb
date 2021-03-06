Bitcoin.require_dependency :sequel, message:
  "Note: You will also need an adapter for your database like sqlite3, mysql2, postgresql"
require_relative 'migrations'

module Bitcoin::Storage::Backends

  # Storage backend using Sequel to connect to arbitrary SQL databases.
  # Inherits from StoreBase and implements its interface.
  class SequelStore < StoreBase


    # possible script types
    SCRIPT_TYPES = [:unknown, :pubkey, :hash160, :multisig, :p2sh]
    if Bitcoin.namecoin?
      [:name_new, :name_firstupdate, :name_update].each {|n| SCRIPT_TYPES << n }
    end

    # name_new must have 12 confirmations before corresponding name_firstupdate is valid.
    NAMECOIN_FIRSTUPDATE_LIMIT = 12

    # sequel database connection
    attr_accessor :db

    include Bitcoin::Storage::Backends::SequelMigrations

    DEFAULT_CONFIG = { mode: :full, cache_head: false }

    # create sequel store with given +config+
    def initialize config, *args
      @config = DEFAULT_CONFIG.merge(config)
      connect
      super config, *args
    end

    # connect to database
    def connect
      {:sqlite => "sqlite3", :postgres => "pg", :mysql => "mysql",
      }.each do |adapter, name|
        if @config[:db].split(":").first == adapter.to_s
          Bitcoin.require_dependency name, gem: name
        end
      end

      @db = Sequel.connect(@config[:db])
      migrate
    end

    # reset database; delete all data
    def reset
      [:blk, :blk_tx, :tx, :txin, :txout, :addr, :addr_txout, :names].each {|table| @db[table].delete}
      @head = nil
    end

    # persist given block +blk+ to storage.
    def persist_block blk, chain, depth, prev_work = 0
      @db.transaction do
        attrs = {
          :hash => blk.hash.htb.to_sequel_blob,
          :depth => depth,
          :chain => chain,
          :version => blk.ver,
          :prev_hash => blk.prev_block.reverse.to_sequel_blob,
          :mrkl_root => blk.mrkl_root.reverse.to_sequel_blob,
          :time => blk.time,
          :bits => blk.bits,
          :nonce => blk.nonce,
          :blk_size => blk.to_payload.bytesize,
          :work => (prev_work + blk.block_work).to_s
        }
        existing = @db[:blk].filter(:hash => blk.hash.htb.to_sequel_blob)
        if existing.any?
          existing.update attrs
          block_id = existing.first[:id]
        else
          block_id = @db[:blk].insert(attrs)
          blk_tx, new_tx, addrs, names = [], [], [], []

          # store tx
          blk.tx.each.with_index do |tx, idx|
            existing = @db[:tx][hash: tx.hash.htb.to_sequel_blob]
            existing ? blk_tx[idx] = existing[:id] : new_tx << [tx, idx]
          end
          new_tx_ids = @db[:tx].insert_multiple(new_tx.map {|tx, _| tx_data(tx) })
          new_tx_ids.each.with_index {|tx_id, idx| blk_tx[new_tx[idx][1]] = tx_id }

          @db[:blk_tx].insert_multiple(blk_tx.map.with_index {|id, idx|
            { blk_id: block_id, tx_id: id, idx: idx } })

          # store txins
          txin_ids = @db[:txin].insert_multiple(new_tx.map.with_index {|tx, tx_idx|
            tx, _ = *tx
            tx.in.map.with_index {|txin, txin_idx|
              txin_data(new_tx_ids[tx_idx], txin, txin_idx) } }.flatten)

          # store txouts
          txout_i = 0
          txout_ids = @db[:txout].insert_multiple(new_tx.map.with_index {|tx, tx_idx|
            tx, _ = *tx
            tx.out.map.with_index {|txout, txout_idx|
              script_type, a, n = *parse_script(txout, txout_i)
              addrs += a; names += n; txout_i += 1
              txout_data(new_tx_ids[tx_idx], txout, txout_idx, script_type) } }.flatten)

          # store addrs
          persist_addrs addrs.map {|i, h| [txout_ids[i], h]}
          names.each {|i, script| store_name(script, txout_ids[i]) }
        end
        @head = wrap_block(attrs.merge(id: block_id))  if chain == MAIN
        @db[:blk].where(:prev_hash => blk.hash.htb.to_sequel_blob, :chain => ORPHAN).each do |b|
          log.debug { "connecting orphan #{b[:hash].hth}" }
          begin
            store_block(get_block(b[:hash].hth))
          rescue SystemStackError
            EM.defer { store_block(get_block(b[:hash].hth)) }  if EM.reactor_running?
          end
        end
        return depth, chain
      end
    end

    # update +attrs+ for block with given +hash+.
    def update_blocks updates
      @db.transaction do
        updates.each do |blocks, attrs|
          @db[:blk].filter(:hash => blocks.map{|h| h.htb.to_sequel_blob}).update(attrs)
        end
      end
    end

    # parse script and collect address/txout mappings to index
    def parse_script txout, i
      addrs, names = [], []
      # skip huge script in testnet3 block 54507 (998000 bytes)
      return [SCRIPT_TYPES.index(:unknown), [], []]  if txout.pk_script.bytesize > 10_000

      script = Bitcoin::Script.new(txout.pk_script) rescue nil
      if script
        if script.is_hash160? || script.is_pubkey?
          addrs << [i, script.get_hash160]
        elsif script.is_multisig?
          script.get_multisig_pubkeys.map do |pubkey|
            addrs << [i, Bitcoin.hash160(pubkey.unpack("H*")[0])]
          end
        elsif Bitcoin.namecoin? && script.is_namecoin?
          addrs << [i, script.get_hash160]
          names << [i, script]
        else
          log.warn { "Unknown script type"}# #{tx.hash}:#{txout_idx}" }
        end
        script_type = SCRIPT_TYPES.index(script.type)
      else
        log.error { "Error parsing script"}# #{tx.hash}:#{txout_idx}" }
        script_type = SCRIPT_TYPES.index(:unknown)
      end
      [script_type, addrs, names]
    end

    # bulk-store addresses and txout mappings
    def persist_addrs addrs
      addr_txouts, new_addrs = [], []
      addrs.group_by {|_, a| a }.each do |hash160, txouts|
        if existing = @db[:addr][:hash160 => hash160]
          txouts.each {|id, _| addr_txouts << [existing[:id], id] }
        else
          new_addrs << [hash160, txouts.map {|id, _| id }]
        end
      end
      new_addr_ids = @db[:addr].insert_multiple(new_addrs.map {|hash160, txout_id|
        { hash160: hash160 } })
      new_addr_ids.each.with_index do |addr_id, idx|
        new_addrs[idx][1].each do |txout_id|
          addr_txouts << [addr_id, txout_id]
        end
      end
      @db[:addr_txout].insert_multiple(addr_txouts.map {|addr_id, txout_id|
        { addr_id: addr_id, txout_id: txout_id }})
    end

    # prepare transaction data for storage
    def tx_data tx
      { hash: tx.hash.htb.to_sequel_blob,
        version: tx.ver, lock_time: tx.lock_time,
        coinbase: tx.in.size == 1 && tx.in[0].coinbase?,
        tx_size: tx.payload.bytesize }
    end

    # store transaction +tx+
    def store_tx(tx, validate = true)
      @log.debug { "Storing tx #{tx.hash} (#{tx.to_payload.bytesize} bytes)" }
      tx.validator(self).validate(raise_errors: true)  if validate
      @db.transaction do
        transaction = @db[:tx][:hash => tx.hash.htb.to_sequel_blob]
        return transaction[:id]  if transaction
        tx_id = @db[:tx].insert(tx_data(tx))
        tx.in.each_with_index {|i, idx| store_txin(tx_id, i, idx)}
        tx.out.each_with_index {|o, idx| store_txout(tx_id, o, idx)}
        tx_id
      end
    end

    # prepare txin data for storage
    def txin_data tx_id, txin, idx
      { tx_id: tx_id, tx_idx: idx,
        script_sig: txin.script_sig.to_sequel_blob,
        prev_out: txin.prev_out.to_sequel_blob,
        prev_out_index: txin.prev_out_index,
        sequence: txin.sequence.unpack("V")[0] }
    end

    # store input +txin+
    def store_txin(tx_id, txin, idx)
      @db[:txin].insert(txin_data(tx_id, txin, idx))
    end

    # prepare txout data for storage
    def txout_data tx_id, txout, idx, script_type
      { tx_id: tx_id, tx_idx: idx,
        pk_script: txout.pk_script.to_sequel_blob,
        value: txout.value, type: script_type }
    end

    # store output +txout+
    def store_txout(tx_id, txout, idx)
      script_type, addrs, names = *parse_script(txout, idx)
      txout_id = @db[:txout].insert(txout_data(tx_id, txout, idx, script_type))
      persist_addrs addrs.map {|i, h| [txout_id, h] }
      names.each {|i, script| store_name(script, txout_id) }
      txout_id
    end

    # store address +hash160+
    def store_addr(txout_id, hash160)
      addr = @db[:addr][:hash160 => hash160]
      addr_id = addr[:id]  if addr
      addr_id ||= @db[:addr].insert({:hash160 => hash160})
      @db[:addr_txout].insert({:addr_id => addr_id, :txout_id => txout_id})
    end

    # if this is a namecoin script, update the names index
    def store_name(script, txout_id)
      if script.type == :name_new
        log.info { "name_new #{script.get_namecoin_hash}" }
        @db[:names].insert({
            :txout_id => txout_id,
            :hash => script.get_namecoin_hash
          })

      elsif script.type == :name_firstupdate
        name_hash = script.get_namecoin_hash
        name_new = @db[:names].where(:hash => name_hash).order(:txout_id).first
        txout = @db[:txout][id: name_new[:txout_id]] if name_new
        tx = @db[:tx][id: txout[:tx_id]] if txout
        blk_tx = @db[:blk_tx][tx_id: tx[:id]]  if tx
        blk = @db[:blk][id: blk_tx[:blk_id]] if blk_tx
        unless name_new && blk && blk[:chain] == 0
          log.warn { "name_new not found: #{name_hash}" }
          return nil
        end
        unless blk[:depth] <= get_depth - NAMECOIN_FIRSTUPDATE_LIMIT
          log.warn { "name_new not yet valid: #{name_hash}" }
          return nil
        end

        log.info { "#{script.type}: #{script.get_namecoin_name}" }
        @db[:names].where(:txout_id => name_new[:txout_id], :name => nil).update({
            :name => script.get_namecoin_name.to_s.to_sequel_blob })
        @db[:names].insert({
            :txout_id => txout_id,
            :hash => name_hash,
            :name => script.get_namecoin_name.to_s.to_sequel_blob,
            :value => script.get_namecoin_value.to_s.to_sequel_blob,
          })
      elsif script.type == :name_update
        log.info { "#{script.type}: #{script.get_namecoin_name}" }
        @db[:names].insert({
            :txout_id => txout_id,
            :name => script.get_namecoin_name.to_s.to_sequel_blob,
            :value => script.get_namecoin_value.to_s.to_sequel_blob,
          })
      end
    end

    # delete transaction
    # TODO: also delete blk_tx mapping
    def delete_tx(hash)
      log.debug { "Deleting tx #{hash} since all its outputs are spent" }
      @db.transaction do
        tx = get_tx(hash)
        tx.in.each {|i| @db[:txin].where(:id => i.id).delete }
        tx.out.each {|o| @db[:txout].where(:id => o.id).delete }
        @db[:tx].where(:id => tx.id).delete
      end
    end

    # check if block +blk_hash+ exists
    def has_block(blk_hash)
      !!@db[:blk].where(:hash => blk_hash.htb.to_sequel_blob).get(1)
    end

    # check if transaction +tx_hash+ exists
    def has_tx(tx_hash)
      !!@db[:tx].where(:hash => tx_hash.htb.to_sequel_blob).get(1)
    end

    # get head block (highest block from the MAIN chain)
    def get_head
      (@config[:cache_head] && @head) ? @head :
        @head = wrap_block(@db[:blk].filter(:chain => MAIN).order(:depth).last)
    end

    # get depth of MAIN chain
    def get_depth
      return -1  unless get_head
      get_head.depth
    end

    # get block for given +blk_hash+
    def get_block(blk_hash)
      wrap_block(@db[:blk][:hash => blk_hash.htb.to_sequel_blob])
    end

    # get block by given +depth+
    def get_block_by_depth(depth)
      wrap_block(@db[:blk][:depth => depth, :chain => MAIN])
    end

    # get block by given +prev_hash+
    def get_block_by_prev_hash(prev_hash)
      wrap_block(@db[:blk][:prev_hash => prev_hash.htb.to_sequel_blob, :chain => MAIN])
    end

    # get block by given +tx_hash+
    def get_block_by_tx(tx_hash)
      tx = @db[:tx][:hash => tx_hash.htb.to_sequel_blob]
      return nil  unless tx
      parent = @db[:blk_tx][:tx_id => tx[:id]]
      return nil  unless parent
      wrap_block(@db[:blk][:id => parent[:blk_id]])
    end

    # get block by given +id+
    def get_block_by_id(block_id)
      wrap_block(@db[:blk][:id => block_id])
    end

    # get transaction for given +tx_hash+
    def get_tx(tx_hash)
      wrap_tx(@db[:tx][:hash => tx_hash.htb.to_sequel_blob])
    end

    # get transaction by given +tx_id+
    def get_tx_by_id(tx_id)
      wrap_tx(@db[:tx][:id => tx_id])
    end

    # get corresponding Models::TxIn for the txout in transaction
    # +tx_hash+ with index +txout_idx+
    def get_txin_for_txout(tx_hash, txout_idx)
      tx_hash = tx_hash.htb_reverse.to_sequel_blob
      wrap_txin(@db[:txin][:prev_out => tx_hash, :prev_out_index => txout_idx])
    end

    def get_txout_by_id(txout_id)
      wrap_txout(@db[:txout][:id => txout_id])
    end

    # get corresponding Models::TxOut for +txin+
    def get_txout_for_txin(txin)
      tx = @db[:tx][:hash => txin.prev_out.reverse.to_sequel_blob]
      return nil  unless tx
      wrap_txout(@db[:txout][:tx_idx => txin.prev_out_index, :tx_id => tx[:id]])
    end

    # get all Models::TxOut matching given +script+
    def get_txouts_for_pk_script(script)
      txouts = @db[:txout].filter(:pk_script => script.to_sequel_blob).order(:id)
      txouts.map{|txout| wrap_txout(txout)}
    end

    # get all Models::TxOut matching given +hash160+
    def get_txouts_for_hash160(hash160, unconfirmed = false)
      addr = @db[:addr][:hash160 => hash160]
      return []  unless addr
      txouts = @db[:addr_txout].where(:addr_id => addr[:id])
        .map{|t| @db[:txout][:id => t[:txout_id]] }
        .map{|o| wrap_txout(o) }
      unless unconfirmed
        txouts.select!{|o| @db[:blk][:id => o.get_tx.blk_id][:chain] == MAIN rescue false }
      end
      txouts
    end

    # get all unconfirmed Models::TxOut
    def get_unconfirmed_tx
      @db[:unconfirmed].map{|t| wrap_tx(t)}
    end

    def get_name_by_txout_id txout_id
      wrap_name(@db[:names][:txout_id => txout_id])
    end

    def name_show name
      names = @db[:names].where(:name => name.to_sequel_blob).order(:txout_id).reverse
      return nil  unless names.any?
      wrap_name(names.first)
    end

    def name_history name
      @db[:names].where(:name => name).where("value IS NOT NULL").order(:txout_id)
        .map {|n| wrap_name(n) }.select {|n| n.get_tx.blk_id }
    end

    # wrap given +block+ into Models::Block
    def wrap_block(block)
      return nil  unless block

      data = {:id => block[:id], :depth => block[:depth], :chain => block[:chain], :work => block[:work].to_i, :hash => block[:hash].hth}
      blk = Bitcoin::Storage::Models::Block.new(self, data)

      blk.ver = block[:version]
      blk.prev_block = block[:prev_hash].reverse
      blk.mrkl_root = block[:mrkl_root].reverse
      blk.time = block[:time].to_i
      blk.bits = block[:bits]
      blk.nonce = block[:nonce]

      db[:blk_tx].filter(blk_id: block[:id]).join(:tx, id: :tx_id)
        .order(:idx).each {|tx| blk.tx << wrap_tx(tx, block[:id]) }

      blk.recalc_block_hash
      blk
    end

    # wrap given +transaction+ into Models::Transaction
    def wrap_tx(transaction, block_id = nil)
      return nil  unless transaction

      block_id ||= @db[:blk_tx].join(:blk, id: :blk_id)
        .where(tx_id: transaction[:id], chain: 0).first[:blk_id] rescue nil

      data = {id: transaction[:id], blk_id: block_id}
      tx = Bitcoin::Storage::Models::Tx.new(self, data)

      inputs = db[:txin].filter(:tx_id => transaction[:id]).order(:tx_idx)
      inputs.each { |i| tx.add_in(wrap_txin(i)) }

      outputs = db[:txout].filter(:tx_id => transaction[:id]).order(:tx_idx)
      outputs.each { |o| tx.add_out(wrap_txout(o)) }
      tx.ver = transaction[:version]
      tx.lock_time = transaction[:lock_time]
      tx.hash = tx.hash_from_payload(tx.to_payload)
      tx
    end

    # wrap given +input+ into Models::TxIn
    def wrap_txin(input)
      return nil  unless input
      data = {:id => input[:id], :tx_id => input[:tx_id], :tx_idx => input[:tx_idx]}
      txin = Bitcoin::Storage::Models::TxIn.new(self, data)
      txin.prev_out = input[:prev_out]
      txin.prev_out_index = input[:prev_out_index]
      txin.script_sig_length = input[:script_sig].bytesize
      txin.script_sig = input[:script_sig]
      txin.sequence = [input[:sequence]].pack("V")
      txin
    end

    # wrap given +output+ into Models::TxOut
    def wrap_txout(output)
      return nil  unless output
      data = {:id => output[:id], :tx_id => output[:tx_id], :tx_idx => output[:tx_idx],
        :hash160 => output[:hash160], :type => SCRIPT_TYPES[output[:type]]}
      txout = Bitcoin::Storage::Models::TxOut.new(self, data)
      txout.value = output[:value]
      txout.pk_script = output[:pk_script]
      txout
    end

    def wrap_name(data)
      return nil  unless data
      Bitcoin::Storage::Models::Name.new(self, data)
    end
  end

end
