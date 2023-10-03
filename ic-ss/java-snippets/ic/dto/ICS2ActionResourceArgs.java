package ic.dto;

import java.math.BigInteger;
import java.util.Optional;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public class ICS2ActionResourceArgs {

	@Field(Type.TEXT)
	@Name("id")
	public String id;

	@Field(Type.VARIANT)
	@Name("action")
	public ICS2ResourceAction action;

	@Field(Type.TEXT)
	@Name("name")
	public Optional<String> name;
	
	@Field(Type.TEXT)
	@Name("parent_path")
	public Optional<String> parentPath;	

	@Field(Type.NAT)
	@Name("ttl")
	public Optional<BigInteger> ttl;
	
	@Field(Type.RECORD)
	@Name("http_headers")
	public ICS2NameValue[] httpHeaders;

}
