package ic.impl;

import java.io.File;
import java.io.IOException;
import java.io.Reader;
import java.io.StringReader;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;

import org.apache.commons.lang3.StringUtils;
import org.apache.hc.client5.http.impl.async.CloseableHttpAsyncClient;
import org.apache.hc.client5.http.impl.async.HttpAsyncClients;
import org.apache.hc.core5.http2.HttpVersionPolicy;
import org.apache.hc.core5.reactor.IOReactorConfig;
import org.apache.hc.core5.util.Timeout;
import org.ic4j.agent.Agent;
import org.ic4j.agent.AgentBuilder;
import org.ic4j.agent.ProxyBuilder;
import org.ic4j.agent.ReplicaTransport;
import org.ic4j.agent.http.ReplicaApacheHttpTransport;
import org.ic4j.agent.identity.Identity;
import org.ic4j.agent.identity.Secp256k1Identity;
import org.ic4j.types.Principal;
import org.springframework.stereotype.Service;

import ic.ICS2ApplicationActor;
import ic.ICS2Config;
import ic.ICS2Config.AppConfig;
import ic.ICS2Service;
import ic.ICS2ServiceException;
import ic.dto.ICS2ActionResourceArgs;
import ic.dto.ICS2ActionResourceDto;
import ic.dto.ICS2CommitArgs;
import ic.dto.ICS2IdUrlResult;
import ic.dto.ICS2InputDto;
import ic.dto.ICS2ResourceAction;
import ic.dto.ICS2ResourceArgs;
import ic.dto.ICS2ResponseDto;
import ic.dto.ICS2TextResult;
import com.oneworldonline.microservices.content.utils.FileUtils;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Service
@RequiredArgsConstructor
@Slf4j
public class ICS2ServiceImpl implements ICS2Service {
	
	private final ICS2Config config;
	private final FileUtils fileUtils;
	// default application to be used (from enterprice config)
	private final String def_app = "dcm";
	
	private String resolveApp (String app) {
		return StringUtils.isEmpty(app) ? def_app : app;
	}
	
	@Override
	public String getDefaultDirectory(String app) {
		return config.getAppConfig(resolveApp(app)).getDefaultDirectory();
	}

	@Override
	public ICS2ResponseDto registerDirectory(String app, String name,  boolean breakOnDuplicate, String parentPath) {
		if (StringUtils.isBlank(name)) throw new ICS2ServiceException("Name is missed");
		
		AppConfig appConfig = config.getAppConfig(resolveApp(app));

		String repositoryId = appConfig.getRepository();
		ICS2ResourceArgs resArgs = new ICS2ResourceArgs();
		resArgs.name = name;
		resArgs.parentPath = StringUtils.isBlank(parentPath) ?  Optional.empty() : Optional.of(parentPath);
		Agent agent = null;
		try {
			agent = initAgent(appConfig.getKey());
			ICS2ApplicationActor actor = ProxyBuilder.create(agent, Principal.fromString(appConfig.getApplication()))
					.getProxy(ICS2ApplicationActor.class);

			CompletableFuture<ICS2IdUrlResult> storeF =  breakOnDuplicate ? actor.create_directory(repositoryId, resArgs) : actor.ensure_directory(repositoryId, resArgs);
			ICS2IdUrlResult storeResponse = storeF.get();
			ICS2ResponseDto r = new ICS2ResponseDto();
			if (storeResponse.errValue != null) {
				r.setError(storeResponse.errValue.name());
				r.setRepository(repositoryId);
			} else {
				r.setId(storeResponse.okValue.id);
				r.setPartition(storeResponse.okValue.partition);
				r.setUrl(storeResponse.okValue.url);
				r.setRepository(repositoryId);
			}
			return r;

		} catch (Exception e) {
			log.error("Error occurred while creation a directory in ICS2 storage. Details '{}'", e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		} finally {
			if (agent != null)
				agent.close();
		}
	}
	
	@Override
	public ICS2ResponseDto deleteResource(String app, ICS2ActionResourceDto dto) {
		AppConfig appConfig = config.getAppConfig(resolveApp(app));
		String repositoryId = appConfig.getRepository();
		Agent agent = null;
		try {
			agent = initAgent(appConfig.getKey());
			ICS2ApplicationActor actor = ProxyBuilder.create(agent, Principal.fromString(appConfig.getApplication()))
					.getProxy(ICS2ApplicationActor.class);
			return deleteResourceImpl(actor, repositoryId, dto);
		} catch (Exception e) {
			log.error("Error occurred while removing a resource '{}' / '{}' from ICS2 storage. Details '{}'", dto.getPartition(), dto.getId(), e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		} finally {
			if (agent != null)
				agent.close();
		}
	}
	
	@Override
	public List<ICS2ResponseDto> deleteResources(String app, List<ICS2ActionResourceDto> dtos) {
		List<ICS2ResponseDto> r = new ArrayList<>();
		AppConfig appConfig = config.getAppConfig(resolveApp(app));
		String repositoryId = appConfig.getRepository();
		Agent agent = null;
		try {
			agent = initAgent(appConfig.getKey());
			ICS2ApplicationActor actor = ProxyBuilder.create(agent, Principal.fromString(appConfig.getApplication())).getProxy(ICS2ApplicationActor.class);
			for (ICS2ActionResourceDto dto : dtos) {
				try {
				r.add(deleteResourceImpl(actor, repositoryId, dto));
				}catch (Exception e1) {
					log.error("Error occurred while removing a resource '{}' / '{}' from ICS2 storage. Details '{}'", 
							dto.getPartition(), dto.getId(), e1.getMessage());	
				}
			}

		} catch (Exception e) {
			log.error("Error occurred while removing bulk of resources  from ICS2 storage. Details '{}'", e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		} finally {
			if (agent != null)
				agent.close();
		}
		return r;
	}

	@Override
	public ICS2ResponseDto storeResource(String app, ICS2InputDto input) {
		if (StringUtils.isBlank(input.getName())) throw new ICS2ServiceException("Name is missed");
		if (StringUtils.isBlank(input.getReference()) && StringUtils.isBlank(input.getValue())) throw new ICS2ServiceException("No data specified");

		Agent agent = null;

		File tmpFile = null;
		AppConfig appConfig = config.getAppConfig(resolveApp(app));
		String repositoryId = appConfig.getRepository();
		try {
			agent = initAgent(appConfig.getKey());
			ICS2ApplicationActor actor = ProxyBuilder.create(agent, Principal.fromString(appConfig.getApplication())).getProxy(ICS2ApplicationActor.class);
			return storeResourceImpl(actor, repositoryId, input);
		} catch (Exception e) {
			log.error("Error occurred while uploading a file in ICS2 storage. Details '{}'", e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		} finally {
			Optional.ofNullable(tmpFile).ifPresent(File::delete);
			if (agent != null)
				agent.close();
		}
	}
	
	@Override
	public List<ICS2ResponseDto> storeResources(String app, List<ICS2InputDto> inputs) {
		// reject entire bulk
		for (ICS2InputDto input : inputs) {
			if (StringUtils.isBlank(input.getName())) throw new ICS2ServiceException("Name is missed");
			if (StringUtils.isBlank(input.getReference()) && StringUtils.isBlank(input.getValue())) throw new ICS2ServiceException("No data specified");
		}
		
		List<ICS2ResponseDto> r = new ArrayList<>(inputs.size());
		Agent agent = null;

		File tmpFile = null;
		AppConfig appConfig = config.getAppConfig(resolveApp(app));
		String repositoryId = appConfig.getRepository();
		try {
			agent = initAgent(appConfig.getKey());
			ICS2ApplicationActor actor = ProxyBuilder.create(agent, Principal.fromString(appConfig.getApplication())).getProxy(ICS2ApplicationActor.class);
			for (ICS2InputDto input : inputs) {
				try {
					r.add(storeResourceImpl(actor, repositoryId, input));
				} catch (Exception e1) {
					log.error("Error occurred while storing a resource '{}' [ref '{}' ] into the directory ['{}'] from ICS2 storage. Details '{}'",
							input.getName(), input.getReference(), input.getParentPath(), e1.getMessage());
				}
			}
		} catch (Exception e) {
			log.error("Error occurred while uploading a file in ICS2 storage. Details '{}'", e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		} finally {
			Optional.ofNullable(tmpFile).ifPresent(File::delete);
			if (agent != null)
				agent.close();
		}
		return r;
	}	
	
	private ICS2ResponseDto storeResourceImpl(ICS2ApplicationActor actor, String repositoryId, ICS2InputDto input)
			throws InterruptedException, ExecutionException, IOException {

		byte[] inputData = null;
		ICS2ResourceArgs resArgs = new ICS2ResourceArgs();
		File tmpFile = null;
		String name = input.getName();
		String binding = name + UUID.randomUUID().toString();

		if (input.getReference() != null) {
			tmpFile = fileUtils.urlToFile(input.getReference());
			inputData = Files.readAllBytes(Paths.get(tmpFile.toURI()));
		} else {
			inputData = input.getValue().getBytes();
		}
		resArgs.name = input.getName();
		resArgs.parentPath =  StringUtils.isBlank(input.getParentPath()) ? Optional.empty() : Optional.of(input.getParentPath());
		resArgs.contentType = Optional.ofNullable((input.getContentType() != null ? input.getContentType() : resolveContentType(name)));
		ICS2ResponseDto r = new ICS2ResponseDto();
		if (inputData.length <= config.getChunkSize()) {
			CompletableFuture<ICS2IdUrlResult> storeF = actor.store_resource(repositoryId, inputData, resArgs);
			ICS2IdUrlResult storeResponse = storeF.get();
			if (storeResponse.errValue != null) {
				r.setError(storeResponse.errValue.name());
				r.setRepository(repositoryId);
			} else {
				r.setId(storeResponse.okValue.id);
				r.setPartition(storeResponse.okValue.partition);
				r.setUrl(storeResponse.okValue.url);
				r.setRepository(repositoryId);
			}
		} else {

			List<byte[]> chunks = splitIntoChunks(inputData, config.getChunkSize());
			for (byte[] im : chunks) {
				CompletableFuture<ICS2TextResult> chunkResponse = actor.store_chunk(repositoryId, im, Optional.ofNullable(binding));
				chunkResponse.get();
			}
			ICS2CommitArgs commit = new ICS2CommitArgs();
			// commit by binding key
			commit.binding_key = Optional.of(binding);
			commit.chunks = new String[0];

			CompletableFuture<ICS2IdUrlResult> commitResponseF = actor.commit_batch(repositoryId, commit, resArgs);
			ICS2IdUrlResult commitResponse = commitResponseF.get();
			if (commitResponse.errValue != null) {
				r.setError(commitResponse.errValue.name());
				r.setRepository(repositoryId);
			} else {
				r.setId(commitResponse.okValue.id);
				r.setPartition(commitResponse.okValue.partition);
				r.setUrl(commitResponse.okValue.url);
				r.setRepository(repositoryId);
			}
		}
		return r;
	}	
	
	private ICS2ResponseDto deleteResourceImpl(ICS2ApplicationActor actor, String repositoryId, ICS2ActionResourceDto dto) throws InterruptedException, ExecutionException {
		ICS2ActionResourceArgs resArgs = new ICS2ActionResourceArgs();
		// resource id to remove
		resArgs.id = dto.getId();
		resArgs.action = ICS2ResourceAction.Delete;
		resArgs.parentPath = Optional.empty();
		resArgs.ttl = Optional.empty();
		resArgs.name = Optional.empty();
		
		String targetRepo = StringUtils.isBlank(dto.getRepository()) ? repositoryId : dto.getRepository();

		CompletableFuture<ICS2IdUrlResult> f = actor.execute_action_on_resource(targetRepo, Optional.ofNullable(dto.getPartition()), resArgs);
		ICS2IdUrlResult storeResponse = f.get();
		ICS2ResponseDto r = new ICS2ResponseDto();
		if (storeResponse.errValue != null) {
			r.setError(storeResponse.errValue.name());
			r.setRepository(targetRepo);
		} else {
			r.setId(storeResponse.okValue.id);
			r.setPartition(storeResponse.okValue.partition);
			r.setUrl(storeResponse.okValue.url);
			r.setRepository(targetRepo);
		}
		return r;
	}

	private Agent initAgent(String key) {
		try {
			Reader sourceReader = new StringReader(key);
			Identity identity = Secp256k1Identity.fromPEMFile(sourceReader);
			IOReactorConfig ioReactorConfig = IOReactorConfig.custom().setSoTimeout(Timeout.ofSeconds(config.getSoTimeout())).build();
			CloseableHttpAsyncClient httpClient = HttpAsyncClients.custom().setVersionPolicy(HttpVersionPolicy.FORCE_HTTP_1).setIOReactorConfig(ioReactorConfig).build();
			ReplicaTransport transport = ReplicaApacheHttpTransport.create(config.getLocation(), httpClient);
			Agent agent = new AgentBuilder().transport(transport).identity(identity).build();
			agent.setVerify(false);
			return agent;
		} catch (Exception e) {
			log.error("Error occurred while building agent entity for ICS2 service. Details '{}'", e.getMessage());
			throw new ICS2ServiceException(e.getMessage());
		}
	}

	private List<byte[]> splitIntoChunks(byte[] source, int chunksize) {
		List<byte[]> result = new ArrayList<byte[]>();
		int start = 0;
		while (start < source.length) {
			int end = Math.min(source.length, start + chunksize);
			result.add(Arrays.copyOfRange(source, start, end));
			start += chunksize;
		}

		return result;
	}
	/**
	 * Helper method to resolve http header
	 */
	private String resolveContentType(String name) {
		String lowerName = name.toLowerCase();
		if (lowerName.endsWith(".pdf")) {
			return "application/pdf";
		} else if (lowerName.endsWith(".mp4")) {
			return "video/mp4";
		} else if (lowerName.endsWith(".mp3")) {
			return "audio/mpeg";
		} else if (lowerName.endsWith(".properties")) {
			return "plain/text";
		} else if (lowerName.endsWith(".html") || lowerName.endsWith(".htm")) {
			return "text/html";
		} else if (lowerName.endsWith(".embed")) {
			return "text/html";
		} else if (lowerName.endsWith(".png")) {
			return "image/png";
		} else if (lowerName.endsWith(".jpg") || lowerName.endsWith(".jpeg")) {
			return "image/jpeg";
		} else if (lowerName.endsWith(".gif")) {
			return "image/gif";
		} else
			return null;
	}

}
