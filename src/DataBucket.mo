import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Buffer "mo:base/Buffer";
import Map "mo:base/HashMap";

import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Float "mo:base/Float";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Timer "mo:base/Timer";

import Http "./Http";
import Types "./Types";
import Utils "./Utils";

shared (installation) actor class DataBucket(initArgs : Types.BucketArgs) = this {

    let OWNER = installation.caller;
	// expiration period for chunk = 10 mins (in nanosec)
	let TTL_CHUNK =  10 * 60 * 1_000_000_000;
	// def scan period is 60 min = 3600 sec
	let CLEAN_UP_PERIOD_SEC = 3600;
	let DEF_CSS =  "<style>" # Utils.DEF_BODY_STYLE # "</style>"; 

	stable let ACCESS_TYPE = initArgs.access_type;
	stable let NAME = initArgs.name;
	stable let NETWORK = initArgs.network;
	stable var operators = initArgs.operators;
	// applicable for http_request for html content only
	stable var html_resource_template = Option.make(Utils.DEF_TEMPLATE);
	stable var cleanup_period_sec = CLEAN_UP_PERIOD_SEC;

	private func init_access_tokens (access_token : ?[Types.AccessToken]) : Trie.Trie<Text, Types.AccessToken> {
		var r:Trie.Trie<Text, Types.AccessToken> = Trie.empty();
		if (Option.isSome(access_token)){
			for (at in Utils.unwrap(access_token).vals()) {
				r := Trie.put(r, Utils.text_key(at.token), Text.equal, at).0;
			}
		};
		return r;
	};	
	//  -------------- stable variables ----------------
	stable var resource_state : [(Text, Types.Resource)] = [];
	stable var chunk_state : [(Text, Types.ResourceChunk)] = [];
	stable var chunk_binding_state : [(Text, Types.ChunkBinding)] = [];

	stable var resource_data : Trie.Trie<Text, [Blob]> = Trie.empty();
	stable var access_token : Trie.Trie<Text, Types.AccessToken> = init_access_tokens(initArgs.access_token);

	// increment counter, internal needs
	stable var _internal_increment : Nat = 0;
	// -------------------------------------------------

	// -----  resource metadata and chunks are stored in heap and flushed to stable memory in case of canister upgrade

	// resource information (aka files/folders)
	private var resources = Map.HashMap<Text, Types.Resource>(0, Text.equal, Text.hash);
	// chunks of files (id to chunk)
	private var chunks = Map.HashMap<Text, Types.ResourceChunk>(0, Text.equal, Text.hash);
	// binding between chunks (logical name and chunk)
	private var chunk_bindings = Map.HashMap<Text, Types.ChunkBinding>(0, Text.equal, Text.hash);
	/**
	* Returns binary data of the resource  (from stable memory)
	*/
    private func resource_data_get(id : Text) : ?[Blob] = Trie.get(resource_data, Utils.text_key(id), Text.equal);
	private func access_token_get(id : Text) : ?Types.AccessToken = Trie.get(access_token, Utils.text_key(id), Text.equal);

	private func is_parent_readonly (id :Text) : Bool {
		var r:Bool = false;
		switch (resources.get(id)){
			case (?v) {
				r := _is_readonly(v);
				if (r) return r;
				if (Option.isSome(v.parent)) {
					r := is_parent_readonly(Utils.unwrap(v.parent)); 
					if (r) return r;
				};
			};
			case (null) {};
		};
		return r;
	};

	private func is_leaf_readonly (id:Text) : Bool {
		var r:Bool = false;
		switch (resources.get(id)){
			case (?v) {
				r := _is_readonly(v);
				if (r) return r;
				if (not List.isNil(v.leafs)) {
					for (leaf in List.toIter(v.leafs)){
						r := is_leaf_readonly(leaf);
						if (r) return r;
					};
				};	
			};
			case (null) {};
		};
		return r;
	};		

	private func _is_readonly (r: Types.Resource) : Bool {
		if (Option.isSome(r.readonly)) { 
			return (Time.now() < Utils.unwrap(r.readonly));
		};
		return false;	
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
						removed_directories:=removed_directories+1;
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
	* Removes a resource (folder or file) by its id. If it is a folder, then all child files are removed as well.
	* If it is a file and it is under the folder, then file is removed and the leafs of the folder is updated.
	* Allowed only to the owner or operator of the bucket.
	*/
	private func _delete_resource(resource_id : Text) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(resource_id)) {
			case (?resource) {

				// check if any parent is readonly
				if (is_parent_readonly(resource_id)) return #err(#OperationNotAllowed);
				// check if any leaf is readonly
				if (is_leaf_readonly(resource_id)) return #err(#OperationNotAllowed);				
				
				ignore _delete_by_id (resource_id);

				// check if it is a leaf, need to update the folder and exclude a leaf
				if (Option.isSome(resource.parent)) {
					switch (resources.get(Utils.unwrap(resource.parent))) {
						case (?f) {	
							f.leafs := List.mapFilter<Text, Text>(f.leafs, func lf = if (lf == resource_id) { null } else { ?lf });	
							f.updated := ?Time.now();
						};
						case (null) {};
					};
				};
				return #ok({id = resource_id; url = ""; partition = "" });	
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};

	private func _replace_resource(args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?resource) {
				// assert if not a file
				if (resource.resource_type == #Directory) { return #err(#OperationNotAllowed); };

				// check if any parent is readonly
				if (is_parent_readonly(args.id)) { return #err(#OperationNotAllowed); };

				let payload = Option.get(args.payload,Blob.fromArray([]));
				let content_size = payload.size();				
				if (Option.isSome(resource.did)) {
					// replace resource itself
					let did = Utils.unwrap(resource.did);
					resource_data := Trie.put(resource_data, Utils.text_key(did), Text.equal, [payload]).0;
				};
				resource.content_size := content_size;
				resource.updated := ?Time.now();
				return #ok(build_id_url(args.id, Principal.toText(Principal.fromActor(this))));
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};		

	private func _clean_up_chunks() : () {
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

	private func _clean_up_ttl() : () {
		let now = Time.now();
		let fResources = Map.mapFilter<Text, Types.Resource, Types.Resource>(resources, Text.equal, Text.hash,
			func(key : Text, r : Types.Resource) : ?Types.Resource {
				if (Option.isSome(r.ttl)) { if (now > Utils.unwrap(r.ttl)) return ?r; };
				return null;
			}
		);
		// remove resources 
		for ((key, r) in fResources.entries())	{
			ignore _delete_resource(key);
		};
	};

	private func _clean_up_readonly() : () {
		let now = Time.now();
		var readonly = Buffer.Buffer<Types.Resource>(5);
		for ((key, r) in resources.entries())	{
			if (Option.isSome(r.readonly)) { 
				if (now > Utils.unwrap(r.readonly))  {
					r.readonly:=null;
				};
			};
		};
	};	

	private func _clean_up_access(): () {
		let now = Time.now();
		// remove expired access keys 
		for ((key, a) in Trie.iter(access_token))	{
			if (Option.isSome(a.valid_to)) {
				if (now > Utils.unwrap(a.valid_to)) {
					access_token := Trie.remove(access_token, Utils.text_key(key), Text.equal).0;
				}
			}
		};
	};

	private func _clean_up_expired () : async () {
		_clean_up_chunks();
		_clean_up_ttl();
		_clean_up_access();
		_clean_up_readonly();
	};
	
	stable var timer_cleanup = Timer.recurringTimer(#seconds(cleanup_period_sec), _clean_up_expired);	

	/**
	* Applies list of operators for the storage service
	*/
	public shared ({ caller }) func apply_operators(ids: [Principal]) {
		assert(caller == OWNER);
		operators := ids;
	};

	public shared query func access_list() : async (Types.AccessList) {
		return { owner = OWNER; operators = operators };
	};

	/**
	* Stores a resource (till 2 mb)
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func store_resource (content : Blob, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		_store_resource ([content], resource_args, null);
	};

	/**
	* Replace a resource (till 2 mb). The same effect could be achived by calling execute_action_on_resource!
	* It is a shortcut version to replace a content.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func replace_resource (id: Text, content : Blob) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		_replace_resource ({
			id = id;
			action = #Replace;
			payload = ?content;
			content_type = null; name = null;
			parent_path = null; ttl = null; http_headers = null; readonly = null;
		});
	};

	/**
	* Applies read-only attribute for the existing resource. The same effect could be achived by calling execute_action_on_resource!
	* It is a shortcut version of the method to appy read-only attribute.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func readonly_resource (id: Text, readonly : ?Nat) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		_readonly_resource ({
			id = id;
			action = #ReadOnly;
			payload = null;
			content_type = null; name = null;
			parent_path = null; ttl = null; http_headers = null; readonly = readonly;
		});
	};	

	/**
	* Deletes the resouce by its id. The same effect could be achived by calling execute_action_on_resource!
	* It is a shortcut version to delete a content.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func delete_resource (id: Text) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		_delete_resource (id);
	};		

	/**
	* Triggers a clean up process (expired chunks, expired resources based on ttl)
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({caller}) func clean_up_expired () : async () {
		assert(caller == OWNER or _is_operator(caller));
		await _clean_up_expired();
	};

	/**
	* Stores a chunk of resource. Optional parameter `binding_key` allows to mark the chunks
	* by the logical name and finalize the resource by this name instead of list of chunk ids.
	* Method returns uniq chunk id.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func store_chunk(content : Blob, binding_key : ?Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);

		_internal_increment := _internal_increment + 1;
		let canister_id =  Principal.toText(Principal.fromActor(this));
		// suffix chunk is needed to avoid of situation when chunk id = resource id (but it is very low probability)
		let hex = Utils.hash_time_based(canister_id # "chunk", _internal_increment);

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

	private func _new_directory (break_on_duplicate:Bool, args : Types.ResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		let canister_id = Principal.toText(Principal.fromActor(this));	
		let name_tokens : [Text] = Iter.toArray(Text.tokens(args.name, #char '/'));
		let name_to_apply = name_tokens[0];
		var final_path:Text = name_to_apply;
		var parent_directory_id:?Text = null;
		var parent_opt : ?Types.Resource = null;
		// parent_id is a priority to derive parent_path
		let parent_path = switch (args.parent_id) {
			case (?parent_id) {
				switch (resources.get(parent_id)) {
					case (?p) { ?full_path(p); 	};
					case (null) {return #err(#NotFound);}
				};
			};
			case (null) {args.parent_path;}
		};

		let directory_id = switch (parent_path){
			case (?path) {
				// check if parent_path is already exists. Otherwise returns an error
				let path_tokens : [Text] = Iter.toArray(Text.tokens(path, #char '/'));
				let parent_id:Text = Utils.hash(canister_id, path_tokens);
				parent_directory_id:= ?parent_id;
				final_path := path # "/" # name_to_apply;
				// check if parent already exists.
				switch (resources.get(parent_id)) {
					case (?p) { 
						parent_opt:=?p;
						Utils.hash(canister_id, Utils.join(path_tokens,[name_to_apply]));	
					};
					// parent directory is not exists, error
					case (null) {return #err(#NotFound);}
				};
			};
			case (null) { Utils.hash(canister_id, [name_to_apply]);}
		};
		switch (resources.get(directory_id)) {
			case (?f) { 
				// break the logic based on criteria
				if (break_on_duplicate) return #err(#DuplicateRecord);
				// continue with path creation
				if  (Array.size(name_tokens) > 1) {
    				let next_iteration = Array.subArray<Text>(name_tokens, 1, Array.size(name_tokens) -1);
					let r = _new_directory (break_on_duplicate, {
						content_type = args.content_type;
						name = Text.join("/", next_iteration.vals());
						parent_path = ?final_path;
						parent_id = null;
						ttl = args.ttl;
						readonly = args.readonly;
					});
					return r;
				};
				return #ok(build_id_path_url(directory_id, final_path, canister_id));				
			};
				
			case (null) {
				resources.put(directory_id, {
					resource_type = #Directory;
					var http_headers = [];
					var ttl = args.ttl;
					var readonly = args.readonly;
					var content_size = 0;
					created = Time.now();
					var updated = null;
					var name = name_to_apply;
					var parent = parent_directory_id;
					var leafs = List.nil();
					did = null;
				});
				switch (parent_opt){
					case (?p) { 
						p.leafs := List.push(directory_id, p.leafs);
						p.updated := ?Time.now();
					};
					case (null) {};
				};

				if  (Array.size(name_tokens) > 1) {
    				let next_iteration = Array.subArray<Text>(name_tokens, 1, Array.size(name_tokens) -1);
					let r = _new_directory (break_on_duplicate, {
						content_type = args.content_type;
						name = Text.join("/", next_iteration.vals());
						parent_path = ?final_path;
						parent_id = null;
						ttl = args.ttl;
						readonly = args.readonly;
					});
					return r;
				};
				return #ok(build_id_path_url(directory_id, final_path, canister_id));
			};
		};	

	};

	/**
	* Applies default template to render resource details for html entity requested though the http_request method
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func apply_html_resource_template(template : ?Text) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		html_resource_template:=template;
		return #ok();
	};

	/**
	* Applies default template to render resource details for html entity requested though the http_request method
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func apply_cleanup_period(seconds : Nat) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		cleanup_period_sec:=seconds;
		Timer.cancelTimer (timer_cleanup);
		timer_cleanup:= Timer.recurringTimer(#seconds(cleanup_period_sec), _clean_up_expired);
		return #ok();
	};		
	/**
	* Creates an empty directory (resource with type Directory).
	* If parent_path is specified, then directory is created under the mentioned location if it is exist.
	* If parent location is mentioned but it is not exist, then error is returned.
	* If ttl is specified, then the directory will be removed once this time is reached.
	* Folders are used to organize resources, for convenience, or to deploy logically groupped files.
	* If break_on_duplicate is false, then method doesn't break if direcotry or subdirectory is exists. 
	* In that case method returns  the directory or continue to generate subdirectories.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func new_directory(break_on_duplicate:Bool, args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		if (Utils.invalid_directory_name(args.name)) return #err(#InvalidRequest);
		// break on duplicates
		_new_directory (break_on_duplicate, args);			
	};

	/**
	* Executes an action on the resource : copy, delete or rename.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func execute_action_on_resource(args : Types.ActionResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (args.action){
			case (#Copy) { _copy_resource(args);};
			case (#Delete) {_delete_resource (args.id)};
			case (#Rename) {_rename_resource(args); };
			case (#Replace) {_replace_resource(args); };
			case (#TTL) { _ttl_resource(args); };
			case (#ReadOnly) { _readonly_resource(args); };
			case (#HttpHeaders) {_apply_headers(args.id, Option.get(args.http_headers, []))};
		}
	};

	/**
	* Registers a new access token. If token already here, no errors.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func register_access_token(args : Types.AccessToken) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		access_token := Trie.put(access_token, Utils.text_key(args.token), Text.equal, args).0;
		return #ok();
	};

	/**
	* Removes access token. If token is not there, no errors.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func remove_access_token(token : Text) : async Result.Result<(), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		access_token := Trie.remove(access_token, Utils.text_key(token), Text.equal).0;
		return #ok();
	};		

	public shared query ({ caller }) func http_request(request : Http.Request) : async Http.Response {
		// check download suffix
		switch (Utils.get_resource_id(request.url)) {
			case (?r) {
				let path_size = Array.size(r.path);
				// check access
				if (ACCESS_TYPE == #Private) {
					switch (r.token) {
						case (?t) {
							switch (access_token_get(t)) {
								case (null) {return Http.forbidden()};
								case (?access) {
									if (Option.isSome(access.valid_to)) {
										if (Time.now() > Utils.unwrap(access.valid_to)) return Http.forbidden();
									}
								};
							};
						};
						case (null) {return Http.un_authorized();};
					};
				};
				let resouce_id = switch (r.view_mode) {
					case (#Index) {
						let canister_id = Principal.toText(Principal.fromActor(this));
						if (path_size == 0) {
							Utils.ROOT;
						}
						else if (path_size == 1) {
							Utils.hash(canister_id, r.path);
						} else {
							let by_names = Utils.hash(canister_id, r.path);
        					switch (resources.get(by_names)) {
								case (?d) {by_names;};
								// path till the last element, final id is a name
								case (null) { 
									let k1 = Utils.hash(canister_id, Array.subArray<Text>(r.path, 0, path_size - 1));
									Utils.hash(canister_id, [k1, r.path[path_size-1]]);
								};
							};
						};
					};
					case (_) { 
						if (path_size == 0) return Http.not_found();
						r.path[0]; 
					};
				};
				return resource_http_handler(resouce_id, r.view_mode, r.token, http_request_streaming_callback);
			};
			case null { return Http.not_found();};

		};
	};

    public query func http_request_streaming_callback(token : Http.StreamingCallbackToken) : async Http.StreamingCallbackResponse {
        switch(resource_data_get(token.key)) {
            case (null) { };
            case (?payload)  { return Http.streamContent(token.key, token.index, payload); };
        };
        {
            body = Blob.fromArray([]);
            token = null;
        };
    };

	private func full_path (v: Types.Resource) : Text {
		var path:Text = v.name;
		if (Option.isSome(v.parent)) {
			switch (resources.get(Utils.unwrap(v.parent))){
				case (?p) {
					if (Option.isSome(p.parent)) {
						path := full_path(p) # "/" # path;

					} else  {
						path := p.name # "/" # path;
					}
				};
				case (null) {};
			};
		};
		return path;
	};

	private func clickable_path (path:Text, canister_id:Text, token:?Text) : Text {
		var html:Text = "";
		let root_url = Utils.build_resource_url({resource_id = ""; canister_id = canister_id; network = NETWORK; view_mode = #Index});
		var full_path:Text = "";
		for (p in Text.tokens(path, #char '/')) {
			if (full_path == "") { full_path:=p; }
			else { full_path:=full_path#"/"#p; };
			let url = Utils.build_resource_url({resource_id = full_path; canister_id = canister_id; network = NETWORK; view_mode = #Index});
			html := html # "<div style=\"display: inline; margin:10px;\">&#128193;<a style=\"font-weight:bold;\" href=\"" # Utils.appendTokenParam(url, token) # "\" >"#p#"</a> /</div>";
		};
		return "<div style=\"display: inline; margin:10px;\">&#128193;<a style=\"font-weight:bold;\" href=\"" # Utils.appendTokenParam(root_url, token) # "\" >"#Utils.ROOT#"</a></div>"# html;
	};

	private func render_resource (canister_id: Text, id:Text, r:Types.Resource, directory_path:?Text, token : ?Text) : Text {
		let path = switch (directory_path) {
			case (?p) {p # "/" # r.name;}; 
			case (null) {r.name;};
		};		
		switch (r.resource_type) {
		case (#Directory) {
			var resource_html = "";
			let url = Utils.build_resource_url({resource_id = path; canister_id = canister_id; network = NETWORK; view_mode = #Index});
			resource_html :=resource_html # "<div style=\"margin:10px;\">&#128193; <a style=\"font-weight:bold;\" href=\"" # Utils.appendTokenParam(url, token) # "\" target = \"_self\">"# r.name # "</a>";
			// render readonly icon
			if (Option.isSome(r.readonly)) {
				resource_html := resource_html # "<span title=\"readonly\" style=\"padding-left:30px;\">&#128274;</span>";
			};
			// render ttl icon		
			if (Option.isSome(r.ttl)) {
				resource_html := resource_html # "<span title=\"TTL\" style=\"padding-left:30px;\">&#9202;</span>";
			};
			resource_html := resource_html # "<span style=\"float:right; padding-right:20px;\" class=\"js_date\">"#Int.toText(r.created)#"</span>";
			return resource_html # "</div>";
		};
		case (#File) {
			var resource_html = "";
			let url_download = Utils.build_resource_url({resource_id = id; canister_id = canister_id; network = NETWORK; view_mode = #Download});
			switch (r.parent) {
				case (?p) {
					// under the directory
					let url = Utils.build_resource_url({resource_id = path; canister_id = canister_id; network = NETWORK; view_mode = #Index});
					let url_raw = Utils.build_resource_url({resource_id = id; canister_id = canister_id; network = NETWORK; view_mode = #Open});
					resource_html := resource_html # "<div style=\"margin:10px;\">&#10148;<a style=\"padding-left:30px;\" href=\"" # Utils.appendTokenParam(url, token) # "\" target = \"_self\">"# r.name # "</a>";
					if (Option.isSome(r.readonly)) {
						resource_html := resource_html # "<span title=\"readonly\" style=\"padding-left:30px;\">&#128274;</span>";
					};
					if (Option.isSome(r.ttl)) {
						resource_html := resource_html # "<span title=\"TTL\" style=\"padding-left:30px;\">&#9202;</span>";
					};	
					switch (r.updated) {
						case (?updated) { resource_html := resource_html # "<span style=\"float:right; padding-right:10px;\" class=\"js_date\">"#Int.toText(updated)#"</span>"; };
						case (null) { resource_html := resource_html # "<span style=\"float:right; padding-right:10px;\" class=\"js_no_date\">--- / ---</span>"; }	
					};			
					resource_html := resource_html # "<span style=\"float:right; padding-right:20px;\" class=\"js_date\">"#Int.toText(r.created)#"</span>";
					resource_html := resource_html # "<a style=\"float:right; padding-right:20px;\" href=\"" # Utils.appendTokenParam(url_download, token) #"\" target = \"_blank\">download</a>";
					resource_html := resource_html # "<a style=\"float:right; padding-right:20px;\" href=\"" # Utils.appendTokenParam(url_raw, token) #"\" target = \"_blank\"> raw link</a>";
					return  resource_html # "<span style=\"float:right; padding-right:20px;\">"#  Float.format(#fix 3,Float.fromInt(r.content_size)/1024) #" Kb</span></div>";
				};
				case (null) {
					let url = Utils.build_resource_url({resource_id = id; canister_id = canister_id; network = NETWORK; view_mode = #Open});
					resource_html := resource_html # "<div style=\"margin:10px;\">&#10148;<a style=\"padding-left:30px;\" href=\"" # Utils.appendTokenParam(url, token) # "\" target = \"_self\">"# r.name # "</a>";
					if (Option.isSome(r.readonly)) {
						resource_html := resource_html # "<span title=\"readonly\" style=\"padding-left:30px;\">&#128274;</span>";
					};					
					if (Option.isSome(r.ttl)) {
						resource_html := resource_html # "<span title=\"TTL\" style=\"padding-left:30px;\">&#9202;</span>";
					};
					resource_html := resource_html # "<span style=\"float:right; padding-right:20px;\" class=\"js_date\">"#Int.toText(r.created)#"</span>";
					resource_html := resource_html # "<a style=\"float:right; padding-right:20px;\" href=\"" # Utils.appendTokenParam(url_download, token) #"\" target = \"_blank\">download</a>";
					return  resource_html # "<span style=\"float:right; padding-right:20px;\">"#  Float.format(#fix 3,Float.fromInt(r.content_size)/1024) #" Kb</span></div>";
				};

			};
		};
		};
	};

    private func root_view (view_mode : Types.ViewMode, token:?Text) : Http.Response {
		switch (view_mode) {
			case (#Index) {
				let canister_id = Principal.toText(Principal.fromActor(this));
				var directory_html = "<html><head>"#DEF_CSS#"</head><body>" # "<h2>&#128193; / </h2>";
				var _t_files = 0;
				var _t_dirs:Nat = 0; 

				var files = "";
				var dirs = "";
				for ((id, r) in resources.entries()) {
					if (Option.isNull(r.parent)) {
						switch (r.resource_type) {
							case (#Directory){	
								dirs := dirs # render_resource(canister_id, id, r, null, token); 
								_t_dirs := _t_dirs + 1;
							};
							case (#File) { 
								files := files # render_resource(canister_id, id, r, null, token); 
								_t_files := _t_files + 1;
							};
						} 
					};
		
				};
				directory_html := directory_html # "<span><i>Directories</i> : <span style=\"padding: 0 40 0 5; font-weight:bold;\">"# Nat.toText(_t_dirs) # "</span>";
				directory_html := directory_html # "<i>Files</i> : <span style=\"padding: 0 40 0 5; font-weight:bold;\">"# Nat.toText(_t_files) # "</span></span>";
				let total_f = Trie.size(resource_data);
				// dirs
				let total_d:Nat = resources.size() - total_f;
				directory_html := directory_html # "<span style=\"float:right;\"><i>Total directories</i> : <span style=\"padding: 0 40 0 5; font-weight:bold;\">"# Nat.toText(total_d) # "</span>";
				directory_html := directory_html # "<i>Total files</i> : <span style=\"padding: 0 40 0 5; font-weight:bold;\">"# Nat.toText(total_f) # "</span></span><hr/>";

				directory_html:=directory_html # dirs;
				directory_html:=directory_html # files;
				Http.success([("content-type", "text/html; charset=UTF-8")], Text.encodeUtf8(directory_html # Utils.FORMAT_DATES_SCRIPT # "</body></html>"));
			};
			case (_) {Http.not_found()};
		};
	};	

    private func resource_http_handler(key : Text, view_mode : Types.ViewMode, token:?Text, callback : Http.StreamingCallback) : Http.Response {
		if (key == Utils.ROOT) {
			return root_view (view_mode, token);
		};

		switch (resources.get(key)) {
            case (null) { Http.not_found() };
            case (? v)  {
				if (v.resource_type == #Directory) {
					let canister_id = Principal.toText(Principal.fromActor(this));
					let directory_path = full_path(v);
					var directory_html = "<html><head>"#DEF_CSS#"</head><body>" # "<h2>"# clickable_path(directory_path, canister_id, token)#"</h2>";
				
					var files = Buffer.Buffer<(Text, Types.Resource)>(List.size(v.leafs));
					var dirs = Buffer.Buffer<(Text, Types.Resource)>(List.size(v.leafs));
					for (leaf in List.toIter(v.leafs)) {
						switch (resources.get(leaf)) {
							case (?r) {
								if (r.resource_type == #Directory) dirs.add((leaf, r));
								if (r.resource_type == #File) files.add((leaf, r));
							}; 
							case (null) {};
						};
					};

					directory_html := directory_html # "<span><i>Directories</i> : <span style=\"padding: 0 20 0 5; font-weight:bold;\">"# Nat.toText(dirs.size()) # "</span>";
					directory_html := directory_html # "<i>Files</i> : <span style=\"padding: 0 20 0 5; font-weight:bold;\">"# Nat.toText(files.size()) # "</span></span>";
					if (_is_readonly(v)) {
						directory_html := directory_html # "<span title=\"readonly\" style=\"padding-left:30px;\">&#128274;</span><span style=\"padding-left:20px;\" class=\"js_date\">"#Int.toText(Utils.unwrap(v.readonly))#"</span>";
					};					
					let total_f = Trie.size(resource_data);
					// dirs
					let total_d:Nat = resources.size() - total_f;
					directory_html := directory_html # "<span style=\"float:right;\"><i>Total directories</i> : <span style=\"padding: 0 20 0 5; font-weight:bold;\">"# Nat.toText(total_d) # "</span>";
					directory_html := directory_html # "<i>Total files</i> : <span style=\"padding: 0 20 0 5; font-weight:bold;\">"# Nat.toText(total_f) # "</span></span><hr/>";				

					// render dirs
					Buffer.iterate<(Text, Types.Resource)>(dirs, func (id, r) {
						directory_html := directory_html # render_resource(canister_id, id, r, ?directory_path, token);
					});					
					// render files
					Buffer.iterate<(Text, Types.Resource)>(files, func (id, r) {
						directory_html := directory_html # render_resource(canister_id, id, r, ?directory_path, token);
					});
					return Http.success([("content-type", "text/html; charset=UTF-8")], Text.encodeUtf8(directory_html # Utils.FORMAT_DATES_SCRIPT # "</body></html>"));
				};

				let headers = switch (view_mode) {
					case (#Download) { Utils.join([("Content-Disposition", Text.concat("attachment; filename=", v.name))], v.http_headers);	};
					case (_) {v.http_headers};
				};
				let did = Utils.unwrap(v.did);

				let payload = switch (resource_data_get(did)) {
					case (?p) {p;};
					case (null) {return Http.not_found();};
				};	
                if (payload.size() > 1) {
                    return Http.handleLargeContent(did, headers, payload, callback);
                };
				// wrap html content with template
				if (Option.isSome(html_resource_template) and Text.endsWith(v.name, Utils.HTML_RESOURCE_PATTERN)) {
					switch (Text.decodeUtf8(payload[0])) {
						case (?d) {
							let t = Utils.unwrap(html_resource_template);
							let wrapped = Text.replace(t, #text "${VALUE}", d);
							return Http.success(headers, Text.encodeUtf8(wrapped));
						};
						case (null) { return Http.success(headers, payload[0]);};
					};
				};
                return Http.success(headers, payload[0]);
            };
        };
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

				// commit batch based on the chunk ids matched to binding key
				let r = _commit_batch(ar, resource_args, caller);
				// remove binding key
				chunk_bindings.delete(binding_key);
				r;
			};
			case (null){
				return #err(#NotFound);
			};
		};
	};

	/**
	* Applies http headers for the specified resource (override)
	*/
	private func _apply_headers(resource_id : Text, http_headers: [Types.NameValue]) :  Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(resource_id)) {
			case (?resource) {
				resource.http_headers:= Array.map<Types.NameValue, (Text, Text)>(http_headers, func h = (h.name, h.value) );
				#ok(build_id_url(resource_id, Principal.toText(Principal.fromActor(this))));
			};
			case (_) {
				return #err(#NotFound);
			};
		};
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
	* Registers a new resource entity.
	* If htto_headers are specified, then applies them otherwise build sinlge http header based on the content type
	*/
	private func _store_resource(payload : [Blob], resource_args : Types.ResourceArgs, http_headers: ?[(Text,Text)]) : Result.Result<Types.IdUrl, Types.Errors> {
		if (Utils.invalid_name(resource_args.name)) return #err(#InvalidRequest);
		// increment counter
		_internal_increment  := _internal_increment + 1;
		let canister_id = Principal.toText(Principal.fromActor(this));
		// generated data id
		let did = Utils.hash_time_based(canister_id, _internal_increment);
		var resource_id = did;
		var content_size = 0;
		// reference to directory id
		var parent:?Text = null;
		// destination : specified directory id (priority 1) or specified path (priority 2)
		if (Option.isSome(resource_args.parent_id) or Option.isSome(resource_args.parent_path)) {
			// passed directory path
			let directory_id = switch(resource_args.parent_id) {
				case (?p) {p;};
				case (null) {
					let path_tokens : [Text] = Iter.toArray(Text.tokens(Utils.unwrap(resource_args.parent_path), #char '/'));
					Utils.hash(canister_id, path_tokens);				
				};
			};

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
					f.updated := ?Time.now();
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
					case (null) {[("Content-Type", "application/octet-stream")]};
				};
			};
		};

		// resouce mapping
		resources.put(resource_id, {
			resource_type = #File;
			var http_headers = header;
			var ttl = resource_args.ttl;
			var readonly = resource_args.readonly;
			var content_size = content_size;
			created = Time.now();
			var updated = null;
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
	private func _rename_resource (args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) {
				// directory rename is not supported yet
				if (res.resource_type == #Directory) { return #err(#OperationNotAllowed); };

				// check if any parent is readonly
				if (is_parent_readonly(args.id)) return #err(#OperationNotAllowed);
				// check if any leaf is readonly
				if (is_leaf_readonly(args.id)) return #err(#OperationNotAllowed);

				let canister_id = Principal.toText(Principal.fromActor(this));				
				let file_name = Option.get(args.name, res.name);
				if (Utils.invalid_name(file_name)) return #err(#InvalidRequest);				
				if (file_name == res.name) {return #err(#DuplicateRecord);};
				switch (res.parent) {
					case (?parent) {
						let resource_id = Utils.hash(canister_id, [parent, file_name]);	
						if (Option.isSome(resources.get(resource_id))) { return #err(#DuplicateRecord);};
						res.name := file_name;
						res.parent:= ?parent;
						res.updated:= ?Time.now();
						resources.put(resource_id, res);	
						resources.delete(args.id);
						// add a new one; exclude old leaf
						switch (resources.get(parent)) {
							case (?p) { 
								p.leafs := List.mapFilter<Text, Text>(List.push(resource_id, p.leafs), func lf = if (lf == args.id) { null } else { ?lf });	
								p.updated := ?Time.now();
							};
							case (null) {};
						};
						return #ok(build_id_url(resource_id, canister_id));					
					};
					case (null) {
						// just rename
						res.name := file_name;
						res.updated:= ?Time.now();
						return #ok(build_id_url(args.id, canister_id));			
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
			partition = canister_id
		};
	};

	private func build_id_path_url (resource_id:Text, path:Text, canister_id:Text) : Types.IdUrl {
		return {
			id = resource_id;
			url = Utils.build_resource_url({
				resource_id = path;
				canister_id = canister_id;
				network = NETWORK;
				view_mode = #Index;
			});
			partition = canister_id
		};
	};	

	private func _ttl_resource(args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) { 
				res.ttl := args.ttl; };
			case (_) {
				return #err(#NotFound);
			};
		};
		#ok(build_id_url(args.id, Principal.toText(Principal.fromActor(this))));
	};

	private func _readonly_resource(args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) { 
				res.readonly := args.readonly; };
			case (_) {
				return #err(#NotFound);
			};
		};
		#ok(build_id_url(args.id, Principal.toText(Principal.fromActor(this))));
	};

	private func _copy_resource(args : Types.ActionResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		switch (resources.get(args.id)) {
			case (?res) {
				// clone of the directory is not supported yet
				if (res.resource_type == #Directory) { return #err(#OperationNotAllowed); };
				let canister_id = Principal.toText(Principal.fromActor(this));
				let file_name = Option.get(args.name, "COPY_"#Int.toText(Time.now())#"_"#res.name);
				if (Utils.invalid_name(file_name)) return #err(#InvalidRequest);
				// check further name under the directory to guarantee uniq name (only for directory)
				var parent_id:?Text = null;
				// destination folder : mentioned directory id (priority 1) OR current directory (priority 2)
				
				if (Option.isSome(res.parent) or Option.isSome(args.parent_path)) {
					// passed directory path
					//var directory_id:Text = null;
					let directory_id = switch(args.parent_path) {
						case (?p) { 
							if (p == Utils.ROOT) { Utils.ROOT }
							else {
								let path_tokens : [Text] = Iter.toArray(Text.tokens(p, #char '/'));
								Utils.hash(canister_id, path_tokens);
							}
						};
						case (null) {Option.get(res.parent, Utils.ROOT);};
					};					

					if (directory_id == Utils.ROOT) {
						parent_id :=null;
					} else {
						// reject if directory is not exists
						if (Option.isNull(resources.get(directory_id))) { return #err(#NotFound); };

						// if resource is a part of directory, then name is uniq inside the directory
						let resource_id = Utils.hash(canister_id, [directory_id, file_name]);	
						// file already presend in the directory
						if (Option.isSome(resources.get(resource_id))) { return #err(#DuplicateRecord); };
						parent_id :=?directory_id;
					}

				};
				
				let r_data = Option.get(resource_data_get(Option.get(res.did,"")), []);
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
						parent_path = null;
						parent_id = parent_id;
						ttl = res.ttl;
						readonly = res.readonly;
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
		if (Utils.invalid_name(resource_args.name)) return #err(#InvalidRequest);
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

	public query func get_html_resource_template() : async ?Text {
		return html_resource_template;
	};

	public query func get_cleanup_period_sec() : async Nat {
		return cleanup_period_sec;
	};	

	public query func get_version() : async Text {
		return Utils.VERSION;
	};

	/**
	* Returns information about memory usage and number of created files and folders.
	* This method could be extended.
	*/
	public query func get_status() : async Types.BucketInfo {
		let id = Principal.fromActor(this);
		// only files
		let f = Trie.size(resource_data);
		// dirs
		let d:Nat = resources.size() - f;
		return {
			id = id;
			name = NAME;
			cycles = Utils.get_cycles_balance();
			memory_mb = Utils.get_memory_in_mb();
			heap_mb = Utils.get_heap_in_mb();
			chunks = chunk_state.size();
			files =  f;
			directories = d;
			url = Utils.build_resource_url({resource_id = ""; canister_id = Principal.toText(id); network = NETWORK; view_mode = #Index});
		
		};
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
		timer_cleanup:= Timer.recurringTimer(#seconds(cleanup_period_sec), _clean_up_expired);

	};

  	public shared func wallet_receive() {
    	let amount = Cycles.available();
    	ignore Cycles.accept(amount);
  	};
	
  	public query func available_cycles() : async Nat {
    	return Cycles.balance();
  	};	

};
