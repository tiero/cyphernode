#!/bin/sh

. ./trace.sh
. ./sql.sh
. ./callbacks_job.sh
. ./sendtobitcoinnode.sh
. ./responsetoclient.sh
. ./computefees.sh
. ./blockchainrpc.sh

confirmation_request()
{
	# We are receiving a HTTP request, let's find the TXID from it

	trace "Entering confirmation_request()..."

	local request=${1}
	local txid=$(echo "${request}" | cut -d ' ' -f2 | cut -d '/' -f3)

	confirmation "${txid}"
	return $?
}

confirmation()
{
	trace "Entering confirmation()..."

	local txid=${1}
	local tx_details=$(get_transaction ${txid})

	########################################################################################################
	# First of all, let's make sure we're working on watched addresses...
	local address
	local addresseswhere
	local addresses=$(echo ${tx_details} | jq ".result.details[].address")

	local notfirst=false
	local IFS=$'\n'
	for address in ${addresses}
	do
		trace "[confirmation] address=${address}"

		if ${notfirst}; then
			addresseswhere="${addresseswhere},${address}"
		else
			addresseswhere="${address}"
			notfirst=true
		fi
	done
	local rows=$(sql "SELECT id, address FROM watching WHERE address IN (${addresseswhere}) AND watching")
	if [ ${#rows} -eq 0 ]; then
		trace "[confirmation] No watched address in this tx!"
		return 0
	fi
	########################################################################################################

	local tx=$(sql "SELECT id FROM tx WHERE txid=\"${txid}\"")
	local id_inserted
	local tx_raw_details=$(get_rawtransaction ${txid})
	local tx_nb_conf=$(echo ${tx_details} | jq '.result.confirmations')

	# Sometimes raw tx are too long to be passed as paramater, so let's write
	# it to a temp file for it to be read by sqlite3 and then delete the file
	echo "${tx_raw_details}" > rawtx-${txid}.blob

	if [ -z ${tx} ]; then
		# TX not found in our DB.
		# 0-conf or missed conf (managed or while spending) or spending an unconfirmed
		# (note: spending an unconfirmed TX must be avoided or we'll get here spending an unprocessed watching)

		# Let's first insert the tx in our DB

		local tx_hash=$(echo ${tx_raw_details} | jq '.result.hash')
		local tx_ts_firstseen=$(echo ${tx_details} | jq '.result.timereceived')
		local tx_amount=$(echo ${tx_details} | jq '.result.amount')

		local tx_size=$(echo ${tx_raw_details} | jq '.result.size')
		local tx_vsize=$(echo ${tx_raw_details} | jq '.result.vsize')
		local tx_replaceable=$(echo ${tx_details} | jq '.result."bip125-replaceable"')
		tx_replaceable=$([ ${tx_replaceable} = "yes" ] && echo 1 || echo 0)

		local fees=$(compute_fees "${txid}")
		trace "[confirmation] fees=${fees}"

		# If we missed 0-conf...
		local tx_blockhash=$(echo ${tx_details} | jq '.result.blockhash')
		local tx_blockheight=$(echo ${tx_details} | jq '.result.blockheight')
		local tx_blocktime=$(echo ${tx_details} | jq '.result.blocktime')

		sql "INSERT OR IGNORE INTO tx (txid, hash, confirmations, timereceived, fee, size, vsize, is_replaceable, blockhash, blockheight, blocktime, raw_tx) VALUES (\"${txid}\", ${tx_hash}, ${tx_nb_conf}, ${tx_ts_firstseen}, ${fees}, ${tx_size}, ${tx_vsize}, ${tx_replaceable}, ${tx_blockhash}, ${tx_blockheight}, ${tx_blocktime}, readfile('rawtx-${txid}.blob'))"
		trace_rc $?

		id_inserted=$(sql "SELECT id FROM tx WHERE txid='${txid}'")
		trace_rc $?

	else
		# TX found in our DB.
		# 1-conf or spending watched address (in this case, we probably missed conf)

		local tx_blockhash=$(echo ${tx_details} | jq '.result.blockhash')
		local tx_blockheight=$(echo ${tx_details} | jq '.result.blockheight')
		local tx_blocktime=$(echo ${tx_details} | jq '.result.blocktime')

		sql "UPDATE tx SET
			confirmations=${tx_nb_conf},
			blockhash=${tx_blockhash},
			blockheight=${tx_blockheight},
			blocktime=${tx_blocktime},
			raw_tx=readfile('rawtx-${txid}.blob')
			WHERE txid=\"${txid}\""
		trace_rc $?

		id_inserted=${tx}

	fi
	# Delete the temp file containing the raw tx (see above)
	rm rawtx-${txid}.blob

	########################################################################################################
	# Let's now insert in the join table if not already done
	tx=$(sql "SELECT tx_id FROM watching_tx WHERE tx_id=\"${tx}\"")

	if [ -z "${tx}" ]; then
		trace "[confirmation] For this tx, there's no watching_tx row, let's create"
		local watching_id

		# If the tx is batched and pays multiple watched addresses, we have to insert
		# those additional addresses in watching_tx!
		for row in ${rows}
		do
			watching_id=$(echo "${row}" | cut -d '|' -f1)
			address=$(echo "${row}" | cut -d '|' -f2)
			tx_vout_n=$(echo ${tx_details} | jq ".result.details[] | select(.address==\"${address}\") | .vout")
			tx_vout_amount=$(echo ${tx_details} | jq ".result.details[] | select(.address==\"${address}\") | .amount")
			sql "INSERT OR IGNORE INTO watching_tx (watching_id, tx_id, vout, amount) VALUES (${watching_id}, ${id_inserted}, ${tx_vout_n}, ${tx_vout_amount})"
			trace_rc $?
		done
	else
		trace "[confirmation] For this tx, there's already watching_tx rows"
	fi
	########################################################################################################

	do_callbacks

	echo '{"result":"confirmed"}'

	return 0
}

case "${0}" in *confirmation.sh) confirmation $@;; esac
