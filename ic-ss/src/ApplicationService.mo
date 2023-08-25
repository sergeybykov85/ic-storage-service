import Cycles "mo:base/ExperimentalCycles";
import Array "mo:base/Array";
import List "mo:base/List";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Map "mo:base/HashMap";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import Principal "mo:base/Principal";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Text "mo:base/Text";
import Option "mo:base/Option";

import Application "Application";
import Types "./Types";
import Utils "./Utils";

shared (installation) actor class ApplicationService(initArgs : Types.ApplicationServiceArgs) = this {
	// it is a default contant. this will be managed data soon
	stable let DEF_REPO_PER_APP = 2;

	// owner has a super power, do anything inside this actor and assign any list of operators
    stable let OWNER = installation.caller;

	// operator has enough power, but can't apply a new operator list or change the owner, etc
	stable var operators = initArgs.operators;

    private stable var application_state : [(Principal, Types.CustomerApp)] = [];
	private var applications = Map.HashMap<Principal, Types.CustomerApp>(0, Principal.equal, Principal.hash);

    private stable var customer_state : [(Principal, Types.Customer)] = [];
	private var customers = Map.HashMap<Principal, Types.Customer>(0, Principal.equal, Principal.hash);

	private let management_actor : Types.ICManagementActor = actor "aaaaa-aa";


	public shared query func initParams() : async (Types.ApplicationServiceArgs) {
		return initArgs;
	};	
	/**
	* Applies list of operators for the storage service
	*/
    public shared (msg) func apply_operators(ids: [Principal]) {
    	assert(msg.caller == OWNER);
    	operators := ids;
    };

	public shared ({ caller }) func access_list() : async (Types.AccessList) {
		assert(caller == OWNER or _is_operator(caller));
		return { owner = OWNER; operators = operators }
	};

	public shared ({ caller }) func register_customer (name : Text, description : Text, identity : Principal) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));

		switch (customers.get(identity)) {
			case (?customer) {
				return #err(#AlreadyRegistered);
			};
			case (null) {
				let customer : Types.Customer = {
					var name = name;
					var description = description;			
					identity = identity;
					var applications = List.nil();
					created = Time.now();
				};
				customers.put(identity, customer);
				return #ok(Principal.toText(identity));
			};
		}

	};

	public shared ({ caller }) func register_application_for (name : Text, description : Text, to : Principal) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		await _register_application(name, description, to, null);
	};

	public shared ({ caller }) func register_application (name : Text, description : Text) : async Result.Result<Text, Types.Errors> {
		assert(caller == OWNER or _is_operator(caller));
		await _register_application(name, description, caller, null);
	};

	public shared ({ caller }) func delete_application (id : Text) : async Result.Result<Text, Types.Errors> {
		// only repository owner or application owner can delete
		let app_principal = Principal.fromText(id);
		switch (applications.get(app_principal)) {
			case (?app) {
				// access control : application owner or repository owner
				//if (app.owner != caller) return #err(#NotAuthorized);
				await management_actor.stop_canister({canister_id = app_principal});
				await management_actor.delete_canister({canister_id = app_principal});
				applications.delete(app_principal);
				#ok(id);
			};
			case (null) {
				return #err(#NotFound);
			};
		}
	};	

	private func _register_application (name : Text, description : Text, to : Principal, cycles : ?Nat) : async Result.Result<Text, Types.Errors> {
		switch (customers.get(to))	{
			case (?customer) {
				let cycles_assign = Option.get(cycles, initArgs.cycles_app_init);
				Cycles.add(cycles_assign);
				let application_actor = await Application.Application({
					// default cycles value to be used for any new bucket
					cycles_bucket_init = initArgs.cycles_bucket_init;
					// will be reworked to avoid of a constant
					allowed_repositories = DEF_REPO_PER_APP;
					operators = [to];
					network = initArgs.network;
				});
				
				let application_principal = Principal.fromActor(application_actor);
				let app_id = Principal.toText(application_principal);
				let app : Types.CustomerApp = {
					var name = name;
					var description = description;			
					owner = to;
					created = Time.now();
				};
				applications.put(application_principal, app);
				customer.applications := List.push(app_id, customer.applications);

				return #ok(app_id);
			};
			case (null) {
				// customer is not registered
				return #err(#NotRegistered);
			};
		}
	};

	private func _is_operator(id: Principal) : Bool {
    	Option.isSome(Array.find(operators, func (x: Principal) : Bool { x == id }))
    };	

	public query func total_customers() : async Nat {
		return customers.size();
	};

	public query func total_apps() : async Nat {
		return applications.size();
	};

	/**
	* Returns customer apps for the specified customer.
	*/	
	public shared query func get_application_records_for(customer : Principal) : async [Types.CustomerAppView] {
		_get_application_records_for(customer);
  	};

	/**
	* Returns customer apps for the current user.
	*/	
	public shared ({ caller }) func get_my_application_records() : async [Types.CustomerAppView] {
		_get_application_records_for(caller);
  	};

	private func _get_application_records_for(customer : Principal) : [Types.CustomerAppView] {
    	switch (customers.get(customer)) {
        	case (?c) {
				let res = Buffer.Buffer<Types.CustomerAppView>(List.size(c.applications));

				for (app_id in List.toIter(c.applications)) {
					let app_principal = Principal.fromText(app_id);
					switch (applications.get(app_principal)){
						case (?app) res.add(Utils.customerApp_view(app_principal, app));
						case (null) {
							// nothing
						};
					}
				};
				Buffer.toArray(res);
        	};
        	case (_) {[];};
      	};
  	};	

	/**
	* Returns all registered customer apps.
	*/	
	public shared query func get_application_records() : async [Types.CustomerAppView] {
		return Iter.toArray(Iter.map (applications.entries(), 
			func (i: (Principal, Types.CustomerApp)): Types.CustomerAppView {Utils.customerApp_view(i.0, i.1)}));
	};

	/**
	* Returns all registered customers.
	*/
	public query func get_customer_records() : async [Types.CustomerView] {
		return Iter.toArray(Iter.map (customers.entries(), 
			func (i: (Principal, Types.Customer)): Types.CustomerView {Utils.customer_view(i.1)}));
	};
	
	system func preupgrade() {
		application_state := Iter.toArray(applications.entries());
		customer_state := Iter.toArray(customers.entries());
	};

	system func postupgrade() {
		applications := Map.fromIter<Principal, Types.CustomerApp>(application_state.vals(), application_state.size(), Principal.equal, Principal.hash);
		customers := Map.fromIter<Principal, Types.Customer>(customer_state.vals(), customer_state.size(), Principal.equal, Principal.hash);
		application_state:=[];
		customer_state:=[];
	};

    public shared func wallet_receive() {
      	let amount = Cycles.available();
      	ignore Cycles.accept(amount);
    };
	
  	public query func available_cycles() : async Nat {
    	return Cycles.balance();
  	};	
};
