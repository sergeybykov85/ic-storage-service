package ic;

import java.util.Optional;
import java.util.concurrent.CompletableFuture;

import org.ic4j.agent.annotations.Argument;
import org.ic4j.agent.annotations.UPDATE;
import org.ic4j.agent.annotations.Waiter;
import org.ic4j.candid.annotations.Name;
import org.ic4j.candid.types.Type;

import ic.dto.ICS2ActionResourceArgs;
import ic.dto.ICS2CommitArgs;
import ic.dto.ICS2IdUrlResult;
import ic.dto.ICS2ResourceArgs;
import ic.dto.ICS2TextResult;

public interface ICS2ApplicationActor {
	@UPDATE
	@Name("execute_action_on_resource")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2IdUrlResult> execute_action_on_resource(@Argument(Type.TEXT) String repository_id,
			@Argument(Type.OPT) Optional<String> target_bucket, @Argument(Type.RECORD) ICS2ActionResourceArgs args);

	@UPDATE
	@Name("create_directory")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2IdUrlResult> create_directory(@Argument(Type.TEXT) String repository_id,
			@Argument(Type.RECORD) ICS2ResourceArgs args);
	
	@UPDATE
	@Name("ensure_directory")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2IdUrlResult> ensure_directory(@Argument(Type.TEXT) String repository_id, @Argument(Type.RECORD) ICS2ResourceArgs args);	

	@UPDATE
	@Name("store_resource")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2IdUrlResult> store_resource(@Argument(Type.TEXT) String repository_id,
			@Argument(Type.NAT8) byte[] content, @Argument(Type.RECORD) ICS2ResourceArgs args);

	@UPDATE
	@Name("store_chunk")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2TextResult> store_chunk(@Argument(Type.TEXT) String repository_id,
			@Argument(Type.NAT8) byte[] content, @Argument(Type.OPT) Optional<String> binding);

	@UPDATE
	@Name("commit_batch")
	@Waiter(timeout = 60, sleep = 10)
	public CompletableFuture<ICS2IdUrlResult> commit_batch(@Argument(Type.TEXT) String repository_id,
			@Argument(Type.RECORD) ICS2CommitArgs commitArgs, @Argument(Type.RECORD) ICS2ResourceArgs args);

}
