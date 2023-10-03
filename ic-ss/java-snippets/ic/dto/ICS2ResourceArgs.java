package ic.dto;

import java.math.BigInteger;
import java.util.Optional;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public class ICS2ResourceArgs {

	@Field(Type.TEXT)
	@Name("content_type")
	public Optional<String> contentType;

	@Field(Type.TEXT)
	@Name("name")
	public String name;

	@Field(Type.TEXT)
	@Name("parent_id")
	public Optional<String> parentId;

	@Field(Type.TEXT)
	@Name("parent_path")
	public Optional<String> parentPath;

	@Field(Type.NAT)
	@Name("ttl")
	public Optional<BigInteger> ttl;

}
