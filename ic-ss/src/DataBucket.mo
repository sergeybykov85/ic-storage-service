import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Buffer "mo:base/Buffer";
import Map "mo:base/HashMap";

import Nat "mo:base/Nat";
import Float "mo:base/Float";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Timer "mo:base/Timer";

import Types "./Types";
import Utils "./Utils";

shared (installation) actor class DataBucket(initArgs : Types.BucketArgs) = this {

    let OWNER = installation.caller;
	
	let TTL_CHUNK =  10 * 60 * 1_000_000_000;

	stable let NAME = initArgs.name;
	stable let NETWORK = initArgs.network;
	stable var operators = initArgs.operators;
	//  -------------- stable variables ----------------
	stable var resource_state : [(Text, Types.Resource)] = [];
	stable var chunk_state : [(Text, Types.ResourceChunk)] = [];
	stable var chunk_binding_state : [(Text, Types.ChunkBinding)] = [];

	// file content is stored in the stable memory 
	stable var resource_data : Trie.Trie<Text, [Blob]> = Trie.empty();
	
	// number of all res
	stable var total_files : Nat = 0;
	// number of directories
	stable var total_directories : Nat = 0;
	// increment counter, internal needs
	stable var chunk_increment : Nat = 0;
	// resource counter, internal needs
	stable var resource_increment : Nat = 0;	
	// -------------------------------------------------

	// -----  resource metadata and chunks are stored in heap and flushed to stable memory in case of canister upgrade

	// resource information (aka files/folders)
	private var resources = Map.HashMap<Text, Types.Resource>(0, Text.equal, Text.hash);
	// chunks of files (id to chunk)
	private var chunks = Map.HashMap<Text, Types.ResourceChunk>(0, Text.equal, Text.hash);
	// binding between chunks (logical name and chunk)
	private var chunk_bindings = Map.HashMap<Text, Types.ChunkBinding>(0, Text.equal, Text.hash);

    private func resource_data_get(id : Text) : ?[Blob] = Trie.get(resource_data, Utils.text_key(id), Text.equal);

	private func cleanup_expired() : async () {
		let now = Time.now();
		let fChunks = Map.mapFilter<Text, Types.ResourceChunk, Types.ResourceChunk>(chunks, Text.equal, Text.hash,
			func(key : Text, chunk : Types.ResourceChunk) : ?Types.ResourceChunk {
				let age = now - chunk.created;
				if (age <= TTL_CHUNK) { return ?chunk; }
				else { return null; };
			}
		);
		chunks := fChunks;
		let fBindings = Map.mapFilter<Text, Types.ChunkBinding, Types.ChunkBinding>(chunk_bindings, Text.equal, Text.hash,
			func(key : Text, bind : Types.ChunkBinding) : ?Types.ChunkBinding {
				let age = now - bind.created;
				if (age <= TTL_CHUNK) { return ?bind; } 
				else { return null; };
			}
		);
		chunk_bindings := fBindings;		
	};

	stable var timer_cleanup = Timer.recurringTimer(#seconds(120), cleanup_expired);	

	/**
	* Applies list of operators for the storage service
	*/
	public shared ({ caller }) func apply_operators(ids: [Principal]) {
		assert(caller == OWNER);
		operators := ids;
	};

	public shared ({ caller }) func access_list() : async (Types.AccessList) {
		assert(caller == OWNER or _is_operator(caller));
		return { owner = OWNER; operators = operators };
	};

	/**
	* Stores a resource (till 2 mb)
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func store_resource (content : Blob, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		_store_resource ([content], resource_args, null);
	};

	/**
	* Stores a chunk of resource. Optional parameter `binding_key` allows to mark the chunks
	* by the logical name and finalize the resource by this name instead of list of chunk ids.
	* Method returns uniq chunk id.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func store_chunk(content : Blob, binding_key : ?Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		chunk_increment := chunk_increment + 1;
		let canister_id =  Principal.toText(Principal.fromActor(this));
		// suffix chunk is needed to avoid of situation when chunk id = resource id (but it is very low probability)
		let hex = Utils.hash_time_based(canister_id # "chunk", chunk_increment);

		let chunk : Types.ResourceChunk = {
			content = content;
			created = Time.now();
			id = hex;
			binding_key = binding_key;
		};
		chunks.put(hex, chunk);
		// link a chunk with binding key
		if (Option.isSome(binding_key)) {
			
			let bk = Utils.unwrap(binding_key);
			switch (chunk_bindings.get(bk)) {
				case (?chs) {
					chs.chunks := List.push(hex, chs.chunks);
					//ignore chunk_bindings.replace(bk, chs);
				};
				case (null) {
					chunk_bindings.put(bk, {
						var chunks = List.push(hex, null);
						created = Time.now();
					});
				};
			}
		};
		return #ok(hex);
	};	

	/**
	* Sends cycles to the canister. The destination canister must have a method wallet_receive.
	* It is possible to specify the amount of cycles to leave.
	* Yes, it is possible to call IC.deposit_cycles here to send funds, 
	* but the global idea is to use the "methods of the canister from the ecosystem" to extend them by custom logic if needed.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func withdraw_cycles (args : Types.WitdrawArgs) : async () {
		assert(caller == OWNER or _is_operator(caller));

		let destination = Principal.toText(args.to);
		let wallet : Types.Wallet = actor (destination);
		let cycles = Cycles.balance();
		let cycles_to_leave = Option.get(args.remainder_cycles, 0);
		if  (cycles > cycles_to_leave) {
			let cycles_to_send:Nat = cycles - cycles_to_leave;
			Cycles.add(cycles_to_send);
            await wallet.wallet_receive();
		}
	};	
	/**
	* Creates an empty directory (resource with type Directory).
	* If parent_path is specified, then directory is created under the mentioned location if it is exist.
	* If parent location is mentioned but it is not exist, then error is returned.
	* Folders are used to organize resources, for convenience, or to deploy logically groupped files
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func new_directory(name : Text, parent_path:?Text) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		let canister_id = Principal.toText(Principal.fromActor(this));	
		var parent_directory_id:?Text = null;
		let directory_id = switch (parent_path){
			case (?path) {
				// check if parent_path is already exists. Otherwise returns an error
				let path_tokens : [Text] = Iter.toArray(Text.tokens(path, #char '/'));
				let parent_id:Text = Utils.hash(canister_id, path_tokens);
				parent_directory_id:= ?parent_id;
				// check if parent already exists.
				switch (resources.get(parent_id)) {
					case (?p) { 
						let dir_id = Utils.hash(canister_id, Utils.join(path_tokens, [name]));	
						p.leafs := List.push(dir_id, p.leafs);
						dir_id;
					};
					// parent directory is not exists, error
					case (null) {return #err(#NotFound);}
				};
			};
			case (null) {Utils.hash(canister_id, [name]);}
		};
		switch (resources.get(directory_id)) {
			case (?f) { return #err(#DuplicateRecord); };
			case (null) {
				resources.put(directory_id, {
					resource_type = #Directory;
					var http_headers = [];
					payload = [];
					content_size = 0;
					created = Time.now();
					var name = name;
					var parent = parent_directory_id;
					var leafs = List.nil();
					did = null;
				});
				total_directories  := total_directories + 1;
				return #ok(build_id_url(directory_id, canister_id));
			};
		};			
	};
	/**
	* Executes an action on the resource : copy, delete or rename.
	* Rename covers a simple rename itself or move to the other location
	*/
	public shared ({ caller }) func execute_action(args : Types.ActionResourceArgs) : async Result.Result<(Types.IdUrl), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (args.action){
			case (#Copy) { _copy_resource(args);};
			case (#Delete) {_delete_resource (args.id)};
			case (#Rename) { _move_resource(args); }
		}
	};	

	/**
	* Generates a resource based on the passed chunk ids. Chunks are being removed after this method.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func commit_batch(chunk_ids : [Text], resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		_commit_batch(chunk_ids, resource_args, caller);
	};

	/**
	* Generates a resource based on the passed binding key (logical name for group of chunks). 
	* Chunks are being removed after this method.
	* If binding key doesn't refer to any chunk then err(#NotFound) is returned. Binding key is removed after this method
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func commit_batch_by_key(binding_key : Text, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		switch(chunk_bindings.get(binding_key)) {
			case (?binding){
				if (List.size(binding.chunks) == 0) return #err(#NotFound);
				// validate chunks in any way
				let ar = List.toArray(List.reverse(binding.chunks));

				// remove binding key
				chunk_bindings.delete(binding_key);
				// commit batch based on the chunk ids matched to binding key
				_commit_batch(ar, resource_args, caller);
			};
			case (null){
				return #err(#NotFound);
			};
		};
	};

	/**
	* Applies http headers for the specified resource (override)
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func apply_headers(resource_id : Text, http_headers: [Types.NameValue]) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		switch (resources.get(resource_id)) {
			case (?resource) {
				resource.http_headers:= Array.map<Types.NameValue, (Text, Text)>(http_headers, func h = (h.name, h.value) );
				ignore resources.replace(resource_id, resource);
				return #ok();
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};	

	public query func get_all_resources() : async [Types.ResourceView] {
		let canister_id =  Principal.toText(Principal.fromActor(this));
		return Iter.toArray(Iter.map (resources.entries(), 
			func (i: (Text, Types.Resource)): Types.ResourceView {Utils.resource_view(i.0, i.1, canister_id, NETWORK)}));
	};

	/**
	* Returns information about the resource by id. The resource type is not important here, any kind of the resource is returned.
	* Bytes of the resource are not returned here.
	*/
	public query func get_resource(id : Text) : async Result.Result<Types.ResourceView, Types.Errors> {
		switch (resources.get(id)) {
			case (?res) {
				let canister_id =  Principal.toText(Principal.fromActor(this));	
				return #ok(Utils.resource_view(id, res, canister_id, NETWORK));			
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};

	/**
	* Returns directory details by  its path (location) instead of id
	* Bytes of the resource are not returned here.
	*/
	public query func get_directory_by_path(path : Text) : async Result.Result<Types.DirectoryView, Types.Errors> {
		let canister_id =  Principal.toText(Principal.fromActor(this));	
		let path_tokens : [Text] = Iter.toArray(Text.tokens(path, #char '/'));
		let directory_id:Text = Utils.hash(canister_id, path_tokens);
		switch (resources.get(directory_id)) {
			case (?res) {
				// allowed only for the directory
				if (res.resource_type == #File) return #err (#NotFound);

				var total_size = 0;
				for (leaf in List.toIter(res.leafs)) {
					let r_size = switch (resources.get(leaf)) {
						case (?r) {r.content_size;};
						case (_) {0;}	
					};	
					total_size := total_size + r_size;
				};
				let info : Types.DirectoryView = {
					id = directory_id;
					total_files = List.size(res.leafs);
					total_size = total_size;
					created = res.created;
					url = Utils.build_resource_url({
						resource_id = directory_id;
						canister_id = canister_id;
						network = NETWORK;
						view_mode = #Open;
					});
				};
				return #ok(info);			
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};

	/**
	* Removes a resource (folder or file) by its id. If it is a folder, then all child files are removed as well.
	* If it is a file and it is under the folder, then file is removed and the leafs of the folder is updated.
	* Allowed only to the owner or operator of the bucket.
	*/
	private func _delete_resource(resource_id : Text) : Result.Result<(Types.IdUrl), Types.Errors> {
		switch (resources.get(resource_id)) {
			case (?resource) {
				var removed_directories = 0;
				var removed_files = 0;
				let (f, d) = _delete_by_id (resource_id);
				removed_files := removed_files + f;
				removed_directories := removed_directories + d;				

				// check if it is a leaf, need to update the folder and exclude a leaf
				if (Option.isSome(resource.parent)) {
					let f_id = Utils.unwrap(resource.parent);
					switch (resources.get(f_id)) {
						case (?f) {
							f.leafs := List.mapFilter<Text, Text>(f.leafs,
								func lf = if (lf == f_id) { null } else { ?lf });
						};
						case (null) {};
					};
				};
				// update global var
				if (removed_directories > 0) { total_directories := total_directories - removed_directories; };
				if (removed_files > 0) { total_files := total_files - removed_files; };
				return #ok({id = resource_id; url = ""});	
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};	
	/**
	* Registers a new resource entity.
	* If htto_headers are specified, then applies them otherwise build sinlge http header based on the content type
	*/
	private func _store_resource(payload : [Blob], resource_args : Types.ResourceArgs, http_headers: ?[(Text,Text)]) : Result.Result<Types.IdUrl, Types.Errors> {
		// increment counter
		resource_increment  := resource_increment + 1;
		let canister_id = Principal.toText(Principal.fromActor(this));
		// generated data id
		let did = Utils.hash_time_based(canister_id, resource_increment);
		var resource_id = did;
		var content_size = 0;
		// reference to directory id
		var parent:?Text = null;

		if (Option.isSome(resource_args.directory)) {
			// passed directory path
			let directory = Utils.unwrap(resource_args.directory);
			let path_tokens : [Text] = Iter.toArray(Text.tokens(directory, #char '/'));
			let directory_id:Text = Utils.hash(canister_id, path_tokens);

			// if resource is a part of directory, then name is uniq inside the directory
			resource_id := Utils.hash(canister_id, [directory_id, resource_args.name]);	
			// file already presend in the directory
			if (Option.isSome(resources.get(resource_id))) { return #err(#DuplicateRecord); };
			// parent id for the new resource
			parent :=?directory_id;
			// check if directory by the specified path is already present
			switch (resources.get(directory_id)) {
				case (?f) {
					f.leafs := List.push(resource_id, f.leafs);
					//ignore resources.replace(directory_id, f);
				};
				// directory is not found
				case (null) { return #err(#NotFound); };
			};
		};

		for (p in payload.vals()) {
			content_size := content_size + p.size();
		};

		let header = switch (http_headers){
			case (?hh) {hh;};
			case (null) {
				switch (resource_args.content_type) {
					case (?cp) {[("Content-Type", cp)]};
					case (null) {[]};
				};
			};
		};

		// resouce mapping
		resources.put(resource_id, {
			resource_type = #File;
			var http_headers = header;
			content_size = content_size;
			created = Time.now();
			var name = resource_args.name;
			var parent = parent;
			var leafs = null;
			did = ?did;
		});
		// store data in stable var
		resource_data := Trie.put(resource_data, Utils.text_key(did), Text.equal, payload).0;
		return #ok(build_id_url(resource_id, canister_id));
	};

	/**
	* Renames or moves  the resource entity.
	*/
	private func _move_resource (args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) {
				if (res.resource_type == #Directory) { return #err(#OperationNotAllowed); };
				let canister_id = Principal.toText(Principal.fromActor(this));				
				let file_name = Option.get(args.name, res.name);				

				let new_path_id = switch (args.directory) {
					case (?path) {
						let path_tokens : [Text] = Iter.toArray(Text.tokens(path, #char '/'));
						let dir_id = Utils.hash(canister_id, path_tokens);
						if (Option.isNull(resources.get(dir_id))) { return #err(#NotFound); };
						?dir_id;
					};
					case (null) {null};
				};
				
				switch (res.parent) {
					case (?parent) {
						// new folder or existing one
						let path_id_apply = Option.get(new_path_id, parent);
						let resource_id = Utils.hash(canister_id, [path_id_apply, file_name]);	
						if (Option.isSome(resources.get(resource_id))) { return #err(#DuplicateRecord);};
						res.name := file_name;
						res.parent:= ?path_id_apply;
						resources.put(resource_id, res);	
						resources.delete(args.id);
						// put a new leaf into the folder (new or existing)
						switch (resources.get(path_id_apply)) {
							case (?p) { p.leafs := List.push(resource_id, p.leafs);	};
							case (null) {};
						};
						// exclude old leaf
						switch (resources.get(parent)) {
							case (?p) { p.leafs := List.mapFilter<Text, Text>(p.leafs, func lf = if (lf == args.id) { null } else { ?lf });	};
							case (null) {};
						};
						return #ok(build_id_url(resource_id, canister_id));					
					};
					case (null) {
						if (Option.isSome(new_path_id)) {
							let path_id_apply = Utils.unwrap(new_path_id);
							let resource_id = Utils.hash(canister_id, [path_id_apply, file_name]);	
							if (Option.isSome(resources.get(resource_id))) {return #err(#DuplicateRecord);};
							res.name := file_name;
							res.parent := new_path_id;
							resources.put(resource_id, res);
							resources.delete(args.id);													
							switch (resources.get(path_id_apply)) {
								case (?p) { p.leafs := List.push(resource_id, p.leafs);	};
								case (null) {};
							};
							return #ok(build_id_url(resource_id, canister_id));			
						} else {
							if (file_name == res.name) {return #err(#DuplicateRecord);};
							// just rename
							res.name := file_name;
							return #ok(build_id_url(args.id, canister_id));			
						};
					};
				};

			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};

	private func build_id_url (resource_id:Text, canister_id:Text) : Types.IdUrl {
		return {
			id = resource_id;
			url = Utils.build_resource_url({
				resource_id = resource_id;
				canister_id = canister_id;
				network = NETWORK;
				view_mode = #Open;
			});
		};
	};

	private func _copy_resource(args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) {
				// clone of the directory is not supported
				if (res.resource_type == #Directory) {
					return #err(#OperationNotAllowed);
				};
				let canister_id = Principal.toText(Principal.fromActor(this));
				let file_name = Option.get(args.name, "copy_"#res.name);
				// check further name under the directory to guarantee uniq name (only for directory)
				if (Option.isSome(args.directory)) {
					// passed directory path
					let directory = Utils.unwrap(args.directory);
					let path_tokens : [Text] = Iter.toArray(Text.tokens(directory, #char '/'));
					let directory_id : Text = Utils.hash(canister_id, path_tokens);

					// reject if directory is not exists
					if (Option.isNull(resources.get(directory_id))) {
						return #err(#NotFound);
					};

					// if resource is a part of directory, then name is uniq inside the directory
					let resource_id = Utils.hash(canister_id, [directory_id, file_name]);	
					// file already presend in the directory
					if (Option.isSome(resources.get(resource_id))) {
						return #err(#DuplicateRecord);
					};
				};
				
				let r_data = Option.get(resource_data_get(args.id), []);
				// clone the content of the file
				var content = Buffer.Buffer<Blob>(Array.size(r_data));
				for (d in r_data.vals()){	
					content.add(Blob.fromArray(Blob.toArray(d)));
				};
				// store as a fine
				_store_resource(Buffer.toArray(content), 
					{
						content_type = null;
						name = file_name;
						directory = args.directory;
					},
					?res.http_headers
				);
			};
			case (_) {
				return #err(#NotFound);
			};
		};

	};	

	private func _commit_batch(chunk_ids : [Text], resource_args : Types.ResourceArgs, owner : Principal) : Result.Result<Types.IdUrl, Types.Errors> {
		// entire content of all chunks
		var content = Buffer.Buffer<Blob>(0);
		var content_size = 0;
		
		// logic of validation could be extended
		switch(validate_chunks(chunk_ids)) {
			case (?e) { return #err(e); };
			case (null) { };
		};

		for (id in chunk_ids.vals()) {
			switch (chunks.get(id)) {
				case (?chunk) {
					content.add(chunk.content);
					// remove chunks from map
					chunks.delete(id);
				};
				case (_) {};
			};
		};
		// http headers generated based on the passed content type
		_store_resource (Buffer.toArray(content), resource_args, null);
	};
	/**
	* Deletes resource by its id (either directory or file).
	* Returns number of removed files and directories
	*/
	private func _delete_by_id (id:Text) : (Nat, Nat) {
		var removed_files = 0;
		var removed_directories = 0;
		switch (resources.get(id)) { 
			case (?r) {
				switch (r.resource_type) {
					case (#File) {
						resources.delete(id);
						removed_files:=removed_files+1;
						resource_data := Trie.remove(resource_data, Utils.text_key(Utils.unwrap(r.did)), Text.equal).0;
					};
					case (#Directory) {
						if (not List.isNil(r.leafs)) {
							// delete leafs
							for (leaf in List.toIter(r.leafs)){
								let (f, d) = _delete_by_id(leaf);
								removed_files:=removed_files + f;
								removed_directories:=removed_directories + d;
							}
						};
						resources.delete(id);						
					};
				};
			};
			// ignore
			case (null) {};
		};
		return (removed_files, removed_directories);
	};

	/**
	* Returns information about memory usage and number of created files and folders.
	* This method could be extended.
	*/
	public query func get_status() : async Types.PartitionStatus {
		return {
			cycles = Utils.get_cycles_balance();
			memory_mb = Utils.get_memory_in_mb();
			heap_mb = Utils.get_heap_in_mb();
			files = total_files;
			directories = total_directories;
		};
	};

	public query func get_name() : async Text {
		return NAME;
	};	

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

	private func validate_chunks (chunk_ids : [Text]) : ?Types.Errors {
		// reject the request if any chunk is invalid
		for (id in chunk_ids.vals()) {
			switch (chunks.get(id)) {
				// any logic could be added here
				case (?chunk) {	};
				case (null) {
					return Option.make(#NotFound);
				};
			};
		};
		return null;
	};		

	system func preupgrade() {
		resource_state := Iter.toArray(resources.entries());
		chunk_state := Iter.toArray(chunks.entries());
		Timer.cancelTimer(timer_cleanup);
	};

	system func postupgrade() {
		resources := Map.fromIter<Text, Types.Resource>(resource_state.vals(), resource_state.size(), Text.equal, Text.hash);
		chunks := Map.fromIter<Text, Types.ResourceChunk>(chunk_state.vals(), chunk_state.size(), Text.equal, Text.hash);
		resource_state:=[];
		chunk_state:=[];
		// execute scanner each 2 minutes
		timer_cleanup:= Timer.recurringTimer(#seconds(120), cleanup_expired);

	};

  	public shared func wallet_receive() {
    	let amount = Cycles.available();
    	ignore Cycles.accept(amount);
  	};
	
  	public query func available_cycles() : async Nat {
    	return Cycles.balance();
  	};	

};
