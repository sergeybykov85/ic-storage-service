import Blob "mo:base/Blob";
import HashMap "mo:base/HashMap";
import Option "mo:base/Option";

module Http {
    public type Request = {
        body: Blob;
        headers : [(Text, Text)];
        method : Text;
        url : Text;
    };

    public type Response = {
        body : Blob;
        headers : [(Text, Text)];
        status_code : Nat16;
        streaming_strategy : ?StreamingStrategy;
    };

    public type StreamingStrategy = {
        #Callback: {
            callback : StreamingCallback;
            token : StreamingCallbackToken;
        };
    };

    public type StreamingCallback = query (StreamingCallbackToken) -> async (StreamingCallbackResponse);

    public type StreamingCallbackToken =  {
        content_encoding : Text;
        index : Nat;
        key : Text;
    };

    public type StreamingCallbackResponse = {
        body : Blob;
        token : ?StreamingCallbackToken;
    };

    public func bad_request()  : Response = error(400);
    public func un_authorized() : Response = error(401);
    public func forbidden() : Response = error(403);
    public func not_found()    : Response = error(404);

    private func error(statusCode : Nat16) : Response = {
        status_code = statusCode;
        headers = [];
        body = Blob.fromArray([]);
        streaming_strategy = null;
    };

    public func success (headers : [(Text, Text)], data: Blob) : Response {
        return {
            status_code        = 200;
            headers            = headers;
            body               = data;
            streaming_strategy = null;
       };        
    };

    public func handleLargeContent(key: Text, headers : [(Text, Text)], data: [Blob], callback: StreamingCallback) : Response {
        let (payload, token) = _streamContent(key, 0, data);
        {
            status_code = 200;
            headers = headers;
            body = payload;
            streaming_strategy = switch (token) {
                case (null) { null; };
                case (? tk) {
                    ?#Callback({
                        token    = tk;
                        callback = callback;
                    });
                };
            };
        };
    };

    public func streamContent(key: Text, index: Nat, data: [Blob]) : StreamingCallbackResponse {
        let (payload, cbt) = _streamContent(key, index, data);
        {
            body  = payload;
            token = cbt;
        };
    };

    private func _streamContent(key: Text, index : Nat, data: [Blob]) : (Blob, ?StreamingCallbackToken ) {
        let payload = data[index];
        if (index + 1 == data.size()) return (payload, null);
        (payload, ?{
            content_encoding = "gzip";
            index = index + 1;
            key = key;
        });
    };
};
