import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import List "mo:base/List";

module {

	public type AccessList = {owner : Principal; operators : [Principal]};

	public type NameValue = {
		name : Text;
		value : Text;
	};
	
	// state of the bucket or repository itself
	public type BucketInfo = {
		id : Principal;
		name : Text;
		cycles : Int;
		memory_mb : Int;
		heap_mb : Int;
		chunks : Nat;
		files : Nat;
		directories : Nat;
		url : Text;
	};

	public type ApprovedCustomer = {
		// some status could be added here later
		identity : Principal;
		created: Time.Time;
	};

	public type Customer = {
		var name : Text;
		var description : Text;
		identity : Principal;
		var tier : Tier;
		// principal id
		var applications : List.List<Text>;
		created: Time.Time;
	};

	public type RequestedObject = {
		// path or id
		path : [Text];
		view_mode : ViewMode;
		token : ?Text;
	};

	public type CustomerView = {
		name : Text;
		description : Text;
		identity : Principal;
		tier : Tier;
		applications : [Text];
		created: Time.Time;
	};	

	public type CustomerApp = {
		var name : Text;
		var description : Text;
		owner : Principal;
		created : Time.Time;
	};

	public type CustomerAppView = {
		id : Principal;
		name : Text;
		description : Text;
		owner : Principal;
		created : Time.Time;
	};

	public type AccessType = {
		// anyone can read
		#Public;
		// read operation is restricted
		#Private;
	};

	public type AccessKeyArgs = {
		id : Text;
		name : Text;
		entropy : Text;
		valid_to : ?Time.Time;
	};

	public type AccessKey = {
		id : Text;
		// logical name
		name : Text;
		// never shared
		token : ?Text;
		created : Time.Time;
		valid_to : ?Time.Time;
	};

	public type AccessToken = {
		token : Text;
		created: Time.Time;
		valid_to : ?Time.Time;
	};	

	public type Repository = {
		access_type : AccessType;
		name : Text;
		var description : Text;
		var tags : List.List<Text>;
		var buckets : List.List<Text>;
		var active_bucket : Text;
		var scaling_strategy : ScalingStarategy;
		var bucket_counter: Nat;
		// it is actual for private repo for now
		var access_keys : List.List<AccessKey>;
		created : Time.Time;
		var last_update : ?Time.Time;
	};

	public type RepositoryView = {
		id : Text;
		access_type : AccessType;
		name : Text;
		description : Text;
		tags : [Text];
		buckets : [Text];
		active_bucket : Text;
		scaling_strategy : ScalingStarategy;
		created : Time.Time;
	};

	public type RepositoryDetails = {
		id : Text;
		access_type : AccessType;
		name : Text;
		description : Text;
		tags : [Text];
		buckets : [BucketInfo];
		total_files : Nat;
		total_directories : Nat;		
		active_bucket : Text;
		scaling_strategy : ScalingStarategy;
		created : Time.Time;
	};


	public type RepositoryArgs = {
		name : Text;
		description : Text;
		access_type : AccessType;
		// cycles for a new bucket
		cycles : ?Nat;
		// default stratey is "disabled"
		scaling_strategy : ?ScalingStarategy;
		tags : [Text];
	};

	public type RepositoryUpdateArgs = {
		description : ?Text;
		scaling_strategy : ?ScalingStarategy;
		tags : ?[Text];
	};

	public type CommonUpdateArgs = {
		id: Text;
		name : ?Text;
		description : ?Text;
	};		

	/**
	* Trier represents the list of opportunities.
	* In the first version there is no difference. But limits will be applied based on the tier.
	* (number of apps, number of repos, buckets etc)
	*/
	public type TierId = {
		#Free;
		#Standard;
		#Advanced;
	};

	public type TierOptionsArg = {
		number_of_applications : ?Nat;
		number_of_repositories : ?Nat;
		private_repository_forbidden : ?Bool;
		nested_directory_forbidden : ?Bool;
	};

	public type TierOptions = {
		number_of_applications : Nat;
		number_of_repositories : Nat;
		private_repository_forbidden : Bool;
		nested_directory_forbidden : Bool;
		created : Time.Time;
	};

	public type Tier = {
		id : TierId;
		options : TierOptions;
	};

	public type Network = {
        #IC;
        #Local: Text; // host details like localhost:4943
    };

	public type MemoryThreshold = {
		memory_mb : Int; 
		heap_mb : Int;
	};

	public type ScalingStarategy = {
		#Disabled;
		#Auto : ?MemoryThreshold;
	};

	public type ViewMode = {
		#Index;     // index, names could be used as a part of browser url
		#Open;      // references to the resource by its hash
		#Download;  // reference to the resource by its hash, download in browser
	};

	public type ResourceType = {
		#File;
		#Directory;
	};

	public type ChunkBinding = {
		var chunks : List.List<Text>;
		created : Time.Time;
	};

	public type ResourceChunk = {
		content : Blob;
		created : Time.Time;
		id : Text;
		// opportunity to link chunks by a logical name
		binding_key : ?Text;
	};

	// Type object to create a new resource
	public type ResourceArgs = {
		content_type : ?Text;
		name : Text;
		// input argument, directory name
		parent_path : ?Text;
		// direcotry id. It has a precedence over the parent_path, but this field is not supported in all methods
		parent_id : ?Text;
		ttl : ?Nat;
		read_only : ?Nat;
	};

	public type ResourceAction = {
		#Copy;
		#Delete;
		#Rename;
		#TTL;
		#Replace;
		#ReadOnly;
		#HttpHeaders;
	};
	// Type contains possible required data to make some action with an existing resource
	public type ActionResourceArgs = {
		id : Text;
		action : ResourceAction;
		payload : ?Blob;
		name : ?Text;
		parent_path : ?Text;
		ttl : ?Nat;
		read_only : ?Nat;
		http_headers: ?[NameValue];
	};	

	public type Resource = {
		resource_type : ResourceType;
		var http_headers : [(Text, Text)];
		var ttl : ?Nat;
		// time if no modification allowed : remove or replace (if supported)
		var read_only : ?Nat;
		// resource could be replaced (to remain the same URL)
		var content_size : Nat;
		created : Int;
		var updated : ?Int;
		var name : Text;
		// folder reference (hash, not the name)
		var parent : ?Text;
		// references to other resources in case of "folder type"
		var leafs : List.List<Text>;
		// data identifier 
		did : ?Text;		
	};

	public type ResourceView = {
		id : Text;
		resource_type : ResourceType;
		http_headers : [(Text, Text)];
		content_size : Nat;
		ttl : ?Nat;
		created : Int;
		name : Text;
		url : Text;
	};

	public type IdUrl = {
		id : Text;
		url : Text;
		// usually it is a bucket
		partition : Text;
	};

	public type DirectoryView = {
		id : Text;
		total_files : Nat;
		total_size : Nat;
		created : Int;
		url : Text;
	};		

	public type ApplicationServiceArgs = {
		// network that propagated to any application
		network : Network;
		// list of operators to work with the service
		operators : [Principal];
		// if specified, then this list is included into controllers list for any "registered" canisters 
		spawned_canister_controllers : [Principal];		
		// canister id of the config service
		configuration_service : ?Text;

	};

	public type ApplicationArgs = {
		network : Network;
		// tier of the opportunitites
		tier : Tier;
		// operators to work with a repo
		operators : [Principal];
		// if specified, then this list is included into controllers list for any "registered" canisters 
		spawned_canister_controllers : [Principal];
		// canister id of the config service
		configuration_service : Text;
	};	

	public type BucketArgs = {
		name : Text;
		network : Network;
		operators : [Principal];
		// propagated from repo
		access_type : AccessType;
		access_token : ?[AccessToken];
	};

	public type CommitArgs = {
		chunks : [Text];
		binding_key: ?Text;
	};

	public type WitdrawArgs = {
		to : Principal;
		// cycles to leave before making the withdraw request
		remainder_cycles :?Nat;
	};

	public type Errors = {
		// Tier is not registered
        #TierNotFound;
		// Tier restriction
        #TierRestriction;		
		// no resource or no chunk
		#NotFound;
		// record already registered
		#DuplicateRecord;
		// action not allowed by the logic or constraints
        #OperationNotAllowed;
        // not registered
        #NotRegistered;
		// when input argument contains wrong value
		#InvalidRequest;
        // exceeded allowed items
        #ExceededAllowedLimit;	
		// not authorized to manage certain object
		#AccessDenied;	
    };

    public type ICSettingsArgs = {
        controllers : ?[Principal];
    };	

    public type ICManagementActor = actor {
        stop_canister : shared { canister_id : Principal } -> async ();
		delete_canister : shared { canister_id : Principal } -> async ();
        update_settings : shared {
            canister_id : Principal;
            settings : ICSettingsArgs;
        } -> async ();
    };

	public type Wallet = actor {
    	wallet_receive : () -> async ();
		withdraw_cycles : shared {to : Principal; remainder_cycles : ?Nat} -> async ();
    };

	public type ConfigurationServiceActor = actor {
		get_scaling_memory_options : shared query () -> async MemoryThreshold;
        get_remainder_cycles : shared query () -> async Nat;
		get_app_init_cycles : shared query () -> async Nat;
		get_bucket_init_cycles : shared query () -> async Nat;
		get_tier_options : shared query (t:TierId) -> async Result.Result<TierOptions, Errors>;
	};

	public type ApplicationActor = actor {
		apply_tier : shared (tier : Tier) -> async ();
	};	

    public type DataBucketActor = actor {
		register_access_token : shared(args : AccessToken) -> async Result.Result<(), Errors>;
		remove_access_token : shared(token : Text) -> async Result.Result<(), Errors>;
		new_directory : shared (break_on_duplicate:Bool, args : ResourceArgs) -> async Result.Result<IdUrl, Errors>;
		apply_html_resource_template : shared (template : ?Text) -> async Result.Result<(), Errors>;
		apply_cleanup_period : shared (seconds : Nat) -> async Result.Result<(), Errors>;
        get_status : shared query () -> async BucketInfo;
		clean_up : shared () -> async ();	
		execute_action_on_resource : shared (args : ActionResourceArgs) -> async Result.Result<IdUrl, Errors>;
		store_resource : shared (content : Blob, resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
		store_chunk : shared (content : Blob, binding_key : ?Text ) -> async Result.Result<Text, Errors>;
		commit_batch : shared (chunk_ids : [Text], resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
		commit_batch_by_key : shared (binding_key:Text, resource_args : ResourceArgs ) -> async Result.Result<IdUrl, Errors>;
	};		

};
