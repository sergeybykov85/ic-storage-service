package ic.dto;

import java.util.Optional;

import org.ic4j.candid.annotations.Field;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

public class ICS2CommitArgs {
	@Field(Type.TEXT)
	@Name("chunks")
	public String[] chunks;

	@Field(Type.TEXT)
	@Name("binding_key")
	public Optional<String> binding_key;
}
