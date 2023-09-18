import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import List "mo:base/List";
import Iter "mo:base/Iter";
import Map "mo:base/HashMap";
import Nat "mo:base/Nat";
import Int "mo:base/Int";
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
	stable var tier  = initArgs.tier;
	stable var repositories : Trie.Trie<Text, Types.Repository> = Trie.empty();

	stable var configuration_service =  initArgs.configuration_service;

	let management_actor : Types.ICManagementActor = actor "aaaaa-aa";

	// increment counter, internal needs
	stable var _internal_increment : Nat = 0;	

    private func repository_get(id : Text) : ?Types.Repository = Trie.get(repositories, Utils.text_key(id), Text.equal);	

		
	/**
	* Applies list of operators for the storage service
	*/
    public shared ({ caller }) func apply_operators(ids: [Principal]) {
    	assert(caller == OWNER);
    	operators := ids;
    };

    public shared ({ caller }) func apply_tier (v: Types.Tier) {
    	assert(caller == OWNER);
    	tier :=v;
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
	public shared ({ caller }) func register_repository (args : Types.RepositoryArgs) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		// control number of repositories
		if (Trie.size(repositories) >= tier.options.number_of_repositories) return #err(#TierRestriction);

		let next_id = Trie.size(repositories) + 1;
		let cycles_assign = switch (args.cycles) {
			case (?c) {c;};
			case (null) {
				let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
				await configuration_actor.get_bucket_init_cycles();	
			};
		};		
		let bucket_counter = 1;
		// first vision how to create "advanced bucket name" to have some extra information
		let bucket_name = debug_show({
			application = Principal.fromActor(this);
			repository_name = args.name;
			bucket = "bucket_"#Nat.toText(bucket_counter);
		});
		let repo : Types.Repository = {
			var name = args.name;
			var description = args.description;
			access_type = args.access_type;
			var active_bucket = "";
			var buckets = List.nil();
			var scaling_strategy = Option.get(args.scaling_strategy, #Disabled);
			created = Time.now();
			var access_keys = List.nil();
			var bucket_counter = bucket_counter;
		};

		// create a new bucket
		let bucket = await _register_bucket(repo, [Principal.fromActor(this)], bucket_name, cycles_assign);
		repo.active_bucket:=bucket;
		repo.buckets:=List.push(bucket, repo.buckets);
	
		// generate repository id
		let hex = Utils.hash_time_based(Principal.toText(Principal.fromActor(this)), next_id);

		repositories := Trie.put(repositories, Utils.text_key(hex), Text.equal, repo).0;
		return #ok(hex);
	};

	/**
	* Removes a  repository. All bucket are also removed, cycles are being sent to the application canister.
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_repository (repository_id : Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
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
	* Applies a scaling strategy on the repository and triger "scaling attempt" (if needed)
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func apply_scaling_strategy_on_repository (repository_id : Text, value : Types.ScalingStarategy) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				repo.scaling_strategy:=value;
				ignore await _execute_scaling_attempt (repo);
				return #ok(repository_id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};


	private func _execute_scaling_attempt (repository : Types.Repository) : async Bool {
		let scaling_needed = switch (repository.scaling_strategy) {
			case (#Disabled) {false;};
			case (#Auto memoryThreshold) {
				let bucket_actor : Types.DataBucketActor = actor (repository.active_bucket);
				let bucket_status = await bucket_actor.get_status();
				if (bucket_status.chunks == 0) {
					let ops:Types.MemoryThreshold = switch (memoryThreshold) {
						case (?m) {m;};
						case (null) {
							let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
							await configuration_actor.get_scaling_memory_options();
						};
					};
					(bucket_status.memory_mb >= ops.memory_mb or bucket_status.heap_mb >= ops.heap_mb)
				}
				else  {false}
			};
		};

		if (scaling_needed) {
			let configuration_actor : Types.ConfigurationServiceActor = actor (configuration_service);
			let cycles_assign = await configuration_actor.get_bucket_init_cycles();
			let bucket_counter = repository.bucket_counter + 1;
			let bucket_name = debug_show({
				application = Principal.fromActor(this);
				repository_name = repository.name;
				bucket = "bucket_"#Nat.toText(bucket_counter);
			});

			var access_tokens_opt:?[Types.AccessToken] = null;
			if (List.size(repository.access_keys) > 0) {
				let tokens = List.map(repository.access_keys, func (ac : Types.AccessKey):Types.AccessToken {
					{
						token = Utils.unwrap(ac.token);
						created = ac.created;
						valid_to = ac.valid_to;
					}
				});
				access_tokens_opt:=?List.toArray(tokens);
			};

			let bucket = await _register_bucket(repository, [Principal.fromActor(this)], bucket_name, cycles_assign);
			repository.buckets := List.push(bucket, repository.buckets);
			repository.bucket_counter :=bucket_counter;
			// set the new bucker as an active one
			repository.active_bucket := bucket;
		};
		return scaling_needed;

	};	

	/**
	* Removes a bucket from the existing repository. Active bucket can't be removed.
	* The cycles from the bucket are being sent to the application canister
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_bucket (repository_id : Text, bucket_id: Text) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
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
				let bucket_counter = repo.bucket_counter + 1;
				let bucket_name = debug_show({
					application = Principal.fromActor(this);
					repository_name = repo.name;
					bucket = "bucket_"#Nat.toText(bucket_counter);
				});
				let bucket = await _register_bucket(repo, [Principal.fromActor(this)], bucket_name, cycles_assign);
				repo.buckets := List.push(bucket, repo.buckets);
				repo.bucket_counter := bucket_counter;
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
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);		
		switch (repository_get(repository_id)) {
			case (?repo) {
				// control of nested directories
				if  (tier.options.nested_directory_forbidden and  (Option.isSome(args.parent_path) or Option.isSome(args.parent_id))) return #err(#TierRestriction);

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
				try {
					ignore await _execute_scaling_attempt (repo);
				}catch (e) {
					// nothing needed for now
				};
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
				try {
					ignore await _execute_scaling_attempt (repo);
				}catch (e) {
					// nothing needed for now
				};
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
	public shared ({ caller }) func execute_action_on_resource(repository_id : Text, target_bucket:?Text, args:Types.ActionResourceArgs) : async Result.Result<(Types.IdUrl), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)) {
			case (?repo) {
				let bucket_actor : Types.DataBucketActor = actor (Option.get(target_bucket, repo.active_bucket));
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

	public query func get_tier() : async Types.Tier {
		return tier;
	};

	/**
	* Registers a new access key on the specified repository.
	* Returns `id, and secret key`. Namelly the secret key gives the access to repo. There is no other way to get secet key
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func register_access_key(repository_id : Text, args : Types.AccessKeyArgs) : async Result.Result<(Text, Text), Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)){
			case (?repo) {
				if (repo.access_type == #Public) return #err(#OperationNotAllowed);


				_internal_increment := _internal_increment + 1;
				let canister_id =  Principal.toText(Principal.fromActor(this));
				let now = Time.now();
				let key_id = Utils.hash_time_based(canister_id # "access_key", _internal_increment);
				// lets have a long secret
				let secret_token:Text = Utils.hash(canister_id, [Int.toText(now), args.entropy]) # Utils.hash(repository_id, [Int.toText(now), args.entropy]);
				let ak:Types.AccessKey =  {
					id = key_id;
					name = args.name;
					token = ? secret_token;
					created = now;
					valid_to = args.valid_to;
				};

				repo.access_keys:= List.push(ak, repo.access_keys);

				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					ignore await bucket_actor.register_access_token({
						token = secret_token;
						created = now;
						valid_to = args.valid_to;
					});
				};

				return #ok(key_id, secret_token);
			};
			case (null) {
				return #err(#NotFound);	
			};
		}
	};

	/**
	* Deletes an access key from the repo
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func delete_access_key(repository_id : Text, args : Types.AccessKeyArgs) : async Result.Result<Text, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(repository_id)){
			case (?repo) {
				if (repo.access_type == #Public) return #err(#OperationNotAllowed);
				let after_remove = List.filter(repo.access_keys, func (k:Types.AccessKey):Bool {k.id == args.id} );
				if (List.size(after_remove) == List.size(repo.access_keys)) return #err(#NotFound);
				repo.access_keys:=after_remove;
				return #ok(args.id);
			};
			case (null) {
				return #err(#NotFound);	
			};
		}		
	};	
	/**
	* Returns list of access keys for the repo. Secret key is not returned
	* Allowed only to the owner or operator of the app.
	*/
	public shared ({ caller }) func repository_access_keys(id:Text) : async Result.Result<[Types.AccessKey], Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(id)){
			case (?repo) {
				let _protected = List.map<Types.AccessKey,Types.AccessKey>(repo.access_keys, func (k:Types.AccessKey):Types.AccessKey {
					let r : Types.AccessKey = {
						k with token = null;
					};
					r;
				});
				return #ok(List.toArray(_protected));
			};
			case (null) {
				return #err(#NotFound);	
			};
		}		
	};			

	public shared ({ caller }) func repository_details(id:Text) : async Result.Result<Types.RepositoryDetails, Types.Errors> {
		if (not (caller == OWNER or _is_operator(caller))) return #err(#AccessDenied);
		switch (repository_get(id)){
			case (?repo) {
				var infos = Buffer.Buffer<Types.BucketInfo>(List.size(repo.buckets));
				var total_files = 0;
				var total_directories = 0;
				for (bucket_id in List.toIter(repo.buckets)){
					let bucket = Principal.fromText(bucket_id);
					let bucket_actor : Types.DataBucketActor = actor (bucket_id);
					let i = await bucket_actor.get_status();
					total_files:=total_files + i.files;
					total_directories:=total_directories + i.directories;
					infos.add(i);
				};
				return #ok(	{
						id = id;
						name = repo.name;
						access_type = repo.access_type;
						description = repo.description;
						buckets = Buffer.toArray(infos);
						total_files = total_files;
						total_directories =  total_directories;		
						active_bucket = repo.active_bucket;
						scaling_strategy = repo.scaling_strategy;
						created = repo.created;						
					}
				);
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
	private func _register_bucket(repository:Types.Repository, operators : [Principal], name:Text, cycles : Nat): async Text {
		var access_tokens_opt:?[Types.AccessToken] = null;
		if (List.size(repository.access_keys) > 0) {
			let tokens = List.map(repository.access_keys, func (ac : Types.AccessKey):Types.AccessToken {
				{
					token = Utils.unwrap(ac.token);
					created = ac.created;
					valid_to = ac.valid_to;
				}
			});
			access_tokens_opt:=?List.toArray(tokens);
		};
		
		Cycles.add(cycles);
		let bucket_actor = await DataBucket.DataBucket({
			// apply the user account as operator of the bucket
			name = name;
			operators = operators;
			network = initArgs.network;
			access_type = repository.access_type;
			access_token = access_tokens_opt;
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
