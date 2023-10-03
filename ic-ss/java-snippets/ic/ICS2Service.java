package ic;

import java.util.List;

import com.oneworldonline.microservices.content.services.ic.dto.ICS2ActionResourceDto;
import com.oneworldonline.microservices.content.services.ic.dto.ICS2InputDto;
import com.oneworldonline.microservices.content.services.ic.dto.ICS2ResponseDto;

public interface ICS2Service {
	// returns default directory specified for logical app name from the global config
	String getDefaultDirectory(String app);
	/**
	 * Registers a new directory by given name and parent path.
	 * Name argument could be specified in format a/b/c/d/e.
	 * If breakOnDuplicate is true, then method return error if the directory (or subdir) already present.
	 * If breakOnDuplicate is false and name = a/b/c/d/e and a/b/c already registered, then no error. Method creates missed d/e
	 */
	ICS2ResponseDto registerDirectory(String app, String name, boolean breakOnDuplicate, String parentPath);
	/**
	 * Stores a new resource. Method can download the data from the external reference and stores it as a new IC resource.
	 * Or method could use the given value and stores it as a new IC value
	 * app - logical name of the application according to the global config.
	 * input - details to be saved
	 */
	ICS2ResponseDto storeResource (String app, ICS2InputDto input);
	/**
	 * Stores list of resources
	 */
	List<ICS2ResponseDto> storeResources (String app, List<ICS2InputDto> input);
	
	ICS2ResponseDto deleteResource (String app, ICS2ActionResourceDto dto);
	
	List<ICS2ResponseDto> deleteResources (String app, List<ICS2ActionResourceDto> dtos);
}
