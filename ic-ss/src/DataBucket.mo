import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Cycles "mo:base/ExperimentalCycles";
import Iter "mo:base/Iter";
import List "mo:base/List";
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
	stable var total_resources : Nat = 0;
	// number of directories
	stable var total_folders : Nat = 0;
	// increment counter, internal needs
	stable var chunk_counter : Nat = 0;
	// -------------------------------------------------

	// -----  resources and chunks stored in heap and flushed to stable memory in case of canister upgrade

	// resource information (aka files/folders)
	private var resources = Map.HashMap<Text, Types.Resource>(0, Text.equal, Text.hash);
	// chunks of files
	private var chunks = Map.HashMap<Text, Types.ResourceChunk>(0, Text.equal, Text.hash);
	// binding between chunks
	private var chunk_bindings = Map.HashMap<Text, Types.ChunkBinding>(0, Text.equal, Text.hash);

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
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func store_resource (content : Blob, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		_store_resource ([content], caller, resource_args);
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
	* Creates an empty folder (resource with type Folder).
	* Folders are used to organize resources, for convenience, or to deploy logically groupped files
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func new_folder(folder : Text) : async Result.Result<Types.IdUrl, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));

		let canister_id = Principal.toText(Principal.fromActor(this));				
		let folder_id = Utils.hash(canister_id, [folder]);		
		switch (resources.get(folder_id)) {
			case (?f) {
				return #err(#AlreadyRegistered);				
			};
			case (null) {
				resources.put(folder_id, {
					resource_type = #Folder;
					var http_headers = [];
					payload = [];
					content_size = 0;
					created = Time.now();
					name = folder;
					parent = null;
					var leafs = List.nil();
					});
				total_folders  := total_folders + 1;
				return #ok({
					id = folder_id;
					url = Utils.build_resource_url({
						resource_id = folder_id;
						canister_id = canister_id;
						network = NETWORK;
						view_mode = #Open;
					});
				});
			};
		};			
	};
	/**
	* Removes a resource (folder or file) by its id. If it is a folder, then all child files are removed as well.
	* If it is a file and it is under the folder, then file is removed and the leafs of the folder is updated.
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func delete_resource(resource_id : Text) : async Result.Result<(), Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));

		switch (resources.get(resource_id)) {
			case (?resource) {
				var removed_folders = 0;
				var removed_resources = 0;
				// remove leafs
				if (not List.isNil(resource.leafs)) {
					// delete leafs
					for (leaf in List.toIter(resource.leafs)){
						// leaf is a resource
						removed_resources:=removed_resources + 1;
						resources.delete(leaf);
						resource_data := Trie.remove(resource_data, Utils.text_key(leaf), Text.equal).0;
					}
				};
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

				switch (resource.resource_type) {
					case (#Folder) { removed_folders := removed_folders + 1; };
					case (#File) { removed_resources := removed_resources + 1; };
				};
				if (removed_folders > 0) { total_folders := total_folders - removed_folders; };
				if (removed_resources > 0) { total_resources := total_resources - removed_resources; };
				// delete resource details
				resources.delete(resource_id);
				// delete from stable memory
				resource_data := Trie.remove(resource_data, Utils.text_key(resource_id), Text.equal).0;
				return #ok();
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};


	/**
	* Applies http headers for the specified resource (override)
	* Allowed only to the owner or operator of the bucket.
	*/
	public shared ({ caller }) func apply_headers(resource_id : Text, http_headers: [Types.NameValue]) : async Result.Result<(), Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));

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
	* Returns folder details by  name not the id
	* Bytes of the resource are not returned here.
	*/
	public query func get_folder_info(name : Text) : async Result.Result<Types.FolderView, Types.Errors> {
		let canister_id =  Principal.toText(Principal.fromActor(this));	
		let folder_id = Utils.hash(canister_id, [name]);
		switch (resources.get(folder_id)) {
			case (?res) {
				var total_size = 0;
				for (leaf in List.toIter(res.leafs)) {
					let r_size = switch (resources.get(leaf)) {
						case (?r) {r.content_size;};
						case (_) {0;}	
					};	
					total_size := total_size + r_size;
				};
				let folder_info : Types.FolderView = {
					id = folder_id;
					total_files = List.size(res.leafs);
					total_size = total_size;
					created = res.created;
					url = Utils.build_resource_url({
						resource_id = folder_id;
						canister_id = canister_id;
						network = NETWORK;
						view_mode = #Open;
					});
				};
				return #ok(folder_info);			
			};
			case (_) {
				return #err(#NotFound);
			};
		};
	};

	private func _store_resource(payload : [Blob], owner: Principal, resource_args : Types.ResourceArgs) : Result.Result<Types.IdUrl, Types.Errors> {
		// increment counter
		total_resources  := total_resources + 1;
		// resource hex
		let canister_id = Principal.toText(Principal.fromActor(this));
		var resource_id = Utils.hash_time_based(canister_id, total_resources);	
		var content_size = 0;
		// reference to folder id
		var parent:?Text = null;

		if (Option.isSome(resource_args.folder)) {
			let folder = Utils.unwrap(resource_args.folder);
			let folder_id:Text = Utils.hash(canister_id, [folder]);	
			// if resource is a part of folder, then name is uniq inside the folder
			resource_id := Utils.hash(canister_id, [folder, resource_args.name]);	
			// file already presend in the folder
			if (Option.isSome(resources.get(resource_id))) {
				// reject
				return #err(#AlreadyRegistered);
			};

			switch (resources.get(folder_id)) {
				case (?f) {
					f.leafs := List.push(resource_id, f.leafs);
					ignore resources.replace(folder_id, f);
				};
				case (null) {
					// save new folder
					resources.put(folder_id, {
						resource_type = #Folder;
						var http_headers = [];
						payload = [];
						content_size = 0;
						created = Time.now();
						name = folder;
						parent = null;
						var leafs =  List.push(resource_id, null);
					});
					parent := ?folder_id;
					total_folders  := total_folders + 1;
				};
			};
		};

		for (p in payload.vals()) {
			content_size := content_size + p.size();
		};

		let res : Types.Resource = {
			resource_type = #File;
			var http_headers = [("Content-Type", resource_args.content_type)];
			content_size = content_size;
			created = Time.now();
			name = resource_args.name;
			parent = parent;
			var leafs = null;
		};

		// resouce mapping
		resources.put(resource_id, res);
		// store data
		resource_data := Trie.put(resource_data, Utils.text_key(resource_id), Text.equal, payload).0;

		return #ok({
			id = resource_id;
			url = Utils.build_resource_url({
				resource_id = resource_id;
				canister_id = canister_id;
				network = NETWORK;
				view_mode = #Open;
			});
		});
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
			resources = total_resources;
			folders = total_folders;
		};
	};

	public query func number_of_chunks() : async Nat {
		return chunks.size();
	};

	public query func number_of_resources() : async Nat {
		return total_resources;
	};

	public query func number_of_folders() : async Nat {
		return total_folders;
	};	

	public query func get_name() : async Text {
		return NAME;
	};	

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };		

	system func preupgrade() {
		resource_state := Iter.toArray(resources.entries());
		chunk_state := Iter.toArray(chunks.entries());
	};

	system func postupgrade() {
		resources := Map.fromIter<Text, Types.Resource>(resource_state.vals(), resource_state.size(), Text.equal, Text.hash);
		chunks := Map.fromIter<Text, Types.ResourceChunk>(chunk_state.vals(), chunk_state.size(), Text.equal, Text.hash);
		resource_state:=[];
		chunk_state:=[];
	};

    public shared func wallet_receive() {
      	let amount = Cycles.available();
      	ignore Cycles.accept(amount);
    };
	
  	public query func available_cycles() : async Nat {
    	return Cycles.balance();
  	};	

};
