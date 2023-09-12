import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import Debug "mo:base/Debug";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Map "mo:base/HashMap";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Trie "mo:base/Trie";
import Timer "mo:base/Timer";
import Text "mo:base/Text";
import Option "mo:base/Option";

import DataBucket "DataBucket";
import Types "./Types";
import Utils "./Utils";

shared  (installation) actor class Application(initArgs : Types.ApplicationArgs) = this {

    let OWNER = installation.caller;

 	stable var operators = initArgs.operators;
	stable let tier  = initArgs.tier;
	stable var tier_settings = initArgs.tier_settings;

	stable var repositories : Trie.Trie<Text, Types.Repository> = Trie.empty();

	stable var configuration_service =  initArgs.configuration_service;

	let management_actor : Types.ICManagementActor = actor "aaaaa-aa";

    private func repository_get(id : Text) : ?Types.Repository = Trie.get(repositories, Utils.text_key(id), Text.equal);	

		
	/**
	* Applies list of operators for the storage service
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
    	assert(caller == OWNER);
    	operators := ids;
    };

	public query func get_tier_info() : async (Types.ServiceTier, Types.TierSettings) {
		return (tier, tier_settings);
	};		


	public shared query func access_list() : async (Types.AccessList) {
		return { owner = OWNER; operators = operators };
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
	* Registers a new repository. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func register_repository (name : Text, description : Text, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		// control number of repositories
		if (Trie.size(repositories) >= tier_settings.number_of_repositories) return #err(#TierRestriction);

		let next_id = Trie.size(repositories) + 1;
		let cycles_assign = switch (cycles) {
			case (?c) {c;};
			case (null) {
				let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
				await configuration_actor.get_bucket_init_cycles();	
			};
		};		
		
		// first vision how to create "advanced bucket name" to have some extra information
		let bucket_name = debug_show({
			application = Principal.fromActor(this);
			repository_name = name;
			bucket = "data bucket";
		});
		// create a new bucket
		let bucket = await _register_bucket([Principal.fromActor(this)], bucket_name, cycles_assign);

		// generate repository id
		let hex = Utils.hash_time_based(Principal.toText(Principal.fromActor(this)), next_id);

		let repo : Types.Repository = {
			var name = name;
			var description = description;
			var active_bucket = bucket;
			var buckets = List.push(bucket, null);
			var scaling_strategy = #Disabled;
			created = Time.now();
		};
		repositories := Trie.put(repositories, Utils.text_key(hex), Text.equal, repo).0;
		return #ok(hex);
	};

	/**
	* Removes a  repository. All bucket are also removed, cycles are being sent to the application canister.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_repository (repository_id : Text) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let ic_storage_wallet : Types.Wallet = actor (bucket_id);

					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let remainder_cycles = await configuration_actor.get_remainder_cycles();
					/**
					*  send cycles to "application canister" in case of removing a bucket canister.
					*  right now, remainder_cycles is a constant, the idea is to leave some funds to process the request
					*/
					await ic_storage_wallet.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?remainder_cycles});
					await management_actor.stop_canister({canister_id = bucket});
					await management_actor.delete_canister({canister_id = bucket});
				};
				repositories := Trie.remove(repositories, Utils.text_key(repository_id), Text.equal).0;
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Triggers a cleanup job for the a  repository. If bucket is not specified, then job is triggered for all buckets, otherwise only for the specified bucket.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func clean_up_repository (repository_id : Text, bucket_id : ?Text) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				let to_process = switch (bucket_id) {
					case (?bucket) {List.filter(repo.buckets, func (b:Text):Bool {b == bucket} );};
					case (null) {repo.buckets;}
				};
				for (bucket_id in List.toIter(to_process)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					await bucket_actor.clean_up();
				};
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Applies a scaling strategy on the repository
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func apply_scaling_strategy_on_repository (repository_id : Text, value : Types.ScalingStarategy) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		Debug.print("apply_scaling_strategy_on_repository "#debug_show(value));
		switch (repository_get(repository_id)) {
			case (?repo) {
				repo.scaling_strategy:=value;
				await _check_execute_scaling_attempt (repo);
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};


	/**
	* Tries to execute scaling action
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func trigger_scaling_attempt (repository_id : Text) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		Debug.print("trigger_scaling_attempt on "#debug_show(repository_id));
		switch (repository_get(repository_id)) {
			case (?repo) {
				if (repo.scaling_strategy == #Disabled) return #err(#OperationNotAllowed);
				await _check_execute_scaling_attempt (repo);
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	private func _check_execute_scaling_attempt (repository : Types.Repository) : async (){
		Debug.print("check scaling strategy "#repository.active_bucket);
		let scaling_needed = switch (repository.scaling_strategy) {
			case (#Disabled) {false;};
			case (#Auto) {
				Debug.print("  check scaling strategy Auto");
				let bucket_actor : Types.DataBucketActor = actor (repository.active_bucket);
				let bucket_status = await bucket_actor.get_status();
				if (bucket_status.chunks == 0) {
					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let options = await configuration_actor.get_scaling_memory_options();
					(bucket_status.memory_mb >= options.memory_mb or bucket_status.heap_mb >= options.heap_mb)
				}
				else  {false}
			};
			case (#Manual  memoryThreshold) {
				Debug.print("  check scaling strategy Manual "#debug_show(memoryThreshold));
				let bucket_actor : Types.DataBucketActor = actor (repository.active_bucket);
				let bucket_status = await bucket_actor.get_status();
				(bucket_status.chunks == 0 and (bucket_status.memory_mb >= memoryThreshold.memory_mb or bucket_status.heap_mb >= memoryThreshold.heap_mb));
			};
		};

		if (scaling_needed) {
			Debug.print("   scaling needed, scaling for the buclet "#repository.active_bucket);
			let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
			let cycles_assign = await configuration_actor.get_bucket_init_cycles();
			Debug.print("   scaling needed, cycles_assign "#debug_show(cycles_assign));
			let bucket_name = debug_show({
				application = Principal.fromActor(this);
				repository_name = repository.name;
				bucket = "bucket_"#Nat.toText(List.size(repository.buckets) + 1);
			});
			Debug.print("   try to create a new bucket "#bucket_name);
			let bucket = await _register_bucket([Principal.fromActor(this)], bucket_name, cycles_assign);
			Debug.print("   new  bucket "#bucket);
			repository.buckets := List.push(bucket, repository.buckets);
			// set the new bucker as an active one
			repository.active_bucket := bucket;
		};
		return ();

	};	

	/**
	* Removes a bucket from the existing repository. Active bucket can't be removed.
	* The cycles from the bucket are being sent to the application canister
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_bucket (repository_id : Text, bucket_id: Text) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				if (repo.active_bucket == bucket_id) return #err(#OperationNotAllowed);
				if (Option.isSome(List.find(repo.buckets, func (x: Text) : Bool { x == bucket_id }))) {
					let bucket = Principal.fromText(bucket_id);
					let ic_storage_wallet : Types.Wallet = actor (bucket_id);
					let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
					let remainder_cycles = await configuration_actor.get_remainder_cycles();
					await ic_storage_wallet.withdraw_cycles({to = Principal.fromActor(this); remainder_cycles = ?remainder_cycles});				
					await management_actor.stop_canister({canister_id = bucket});
					await management_actor.delete_canister({canister_id = bucket});
					// exclude bucket id
					repo.buckets := List.mapFilter<Text, Text>(repo.buckets,
						func bk = if (bk == bucket_id) { null } else { ?bk });
					return #ok(bucket_id);
				} else {
					// no such bucket
					return #err(#NotFound);
				}
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Registers  a new bucket inside the repo and sets this backet as an active one. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func new_bucket (repository_id : Text, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let cycles_assign = switch (cycles) {
					case (?c) {c;};
					case (null) {
						let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
						await configuration_actor.get_bucket_init_cycles();
					};
				};
				// first version of the name. Other format might be applied later 
				let bucket_name = debug_show({
					application = Principal.fromActor(this);
					repository_name = repo.name;
					bucket = "bucket_"#Nat.toText(List.size(repo.buckets) + 1);
				});
				let bucket = await _register_bucket([caller], bucket_name, cycles_assign);
				repo.buckets := List.push(bucket, repo.buckets);
				// set the new bucker as an active one
				repo.active_bucket := bucket;
				return #ok(bucket);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Registers  a new bucket inside the repo and sets this backet as an active one. 
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func set_active_bucket (repository_id : Text, bucket_id : Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				switch (List.find(repo.buckets, func (x: Text) : Bool { x == bucket_id })) {
					case (?bucket) {
						repo.active_bucket := bucket;
						return #ok(bucket);
					};
					case (null) {
						// no bucket registered, rejected
						return #err(#NotFound);
					};
				};
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};
	/**
	* Registers a new directory (empty) in the active bucket of the specified repository.  
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func new_directory(repository_id : Text, args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				// control of nested directories
				if  (tier_settings.nested_directory_forbidden and  (Option.isSome(args.parent_path) or Option.isSome(args.parent_id))) return #err(#TierRestriction);

				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.new_directory(args);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	/**
	* Stores a resource (till 2 mb) in the specified repository
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func store_resource(repository_id : Text, content : Blob, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				let r = await bucket_actor.store_resource(content, resource_args);
				await _check_execute_scaling_attempt (repo);
				r;
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Stores a chunk of the resource (file)
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func store_chunk(repository_id : Text, content : Blob, binding_key : ?Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.store_chunk(content, binding_key);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};

	/**
	* Build a resources based on the list of previously uploaded chunks.
	* There are two ways to identify chunks that are used to build a final file : by the list of chunk ids or by the binding name , that was used during chunk upload.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func commit_batch(repository_id : Text, details : Types.CommitArgs, resource_args : Types.ResourceArgs) : async Result.Result<Types.IdUrl, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		// reject invalid data
		if (details.chunks.size() == 0 and Option.isNull(details.binding_key)) return #err(#NotFound);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				let r = switch (details.binding_key){
					case (?binding_key) {
						// commint by key
						await bucket_actor.commit_batch_by_key(binding_key, resource_args);
					};
					case (null) {
						// commint by ids
						await bucket_actor.commit_batch(details.chunks, resource_args);						
					};
				};
				await _check_execute_scaling_attempt (repo);
				r;
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	/**
	* Execute an action on the resource (copy, rename, delete, set ttl).
	* Right now rename of the directory is not supprted, copy of the directory is not suppprted yet.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func execute_action_on_resource(repository_id : Text, args:Types.ActionResourceArgs) : async Result.Result<(Types.IdUrl), Types.Errors> {
		//if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (repo.active_bucket);
				await bucket_actor.execute_action_on_resource(args);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	
	

	public query func get_repository_records() : async [Types.RepositoryView] {
		return Iter.toArray(Iter.map (Trie.iter(repositories), 
			func (i: (Text, Types.Repository)): Types.RepositoryView {Utils.repository_view(i.0, i.1)}));
	};

	public query func get_repository(id:Text) : async Result.Result<Types.RepositoryView, Types.Errors> {
		switch (repository_get(id)){
			case (?repo) {
				return #ok(Utils.repository_view(id, repo));
			};
			case (null) {
				return #err(#NotFound);	
			};
		}
	};

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };

	/**
	* Deploys new bucket canister and returns its id
	*/
	private func _register_bucket(operators : [Principal], name:Text, cycles : Nat): async Text {
		Cycles.add(cycles);
		let bucket_actor = await DataBucket.DataBucket({
			// apply the user account as operator of the bucket
			name = name;
			operators = operators;
			network = initArgs.network;
		});

		let bucket_principal = Principal.fromActor(bucket_actor);
		// IC Application is a controller of the bucket. but other users could be added here
		if (Array.size(initArgs.spawned_canister_controllers) > 0){
			ignore management_actor.update_settings({
				canister_id = bucket_principal;
				settings = { controllers = ? Utils.include(initArgs.spawned_canister_controllers, Principal.fromActor(this));};
			});
		};
		return Principal.toText(bucket_principal);
	};	

	system func preupgrade() { 
	};

	system func postupgrade() {
	};
	
  	public shared func wallet_receive() {
    	let amount = Cycles.available();
    	ignore Cycles.accept(amount);
  	};
	
	public query func available_cycles() : async Nat {
		return Cycles.balance();
  	};	
};
