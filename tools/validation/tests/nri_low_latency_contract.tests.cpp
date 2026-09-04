#include "../../../source/common/rendering/nri/system/nri_low_latency_contract.h"

#include <cstdlib>
#include <iostream>

namespace
{
	void Require(bool condition, const char* message)
	{
		if (!condition)
		{
			std::cerr << "FAILED: " << message << '\n';
			std::exit(1);
		}
	}
}

int main()
{
	using namespace nri_low_latency_contract;

	SwapChainRequest request = {};
	request.nativeRequested = true;
	request.d3d12 = true;
	request.deviceAvailable = true;
	request.swapChainInterfaceAvailable = true;
	request.featureAvailable = true;
	request.interfaceComplete = true;
	Require(ShouldRequestSwapChain(request), "capable native D3D12 request must be admitted");

	request.nativeRequested = false;
	Require(!ShouldRequestSwapChain(request), "request-off must remain a no-op");
	request.frameGenerationRequested = true;
	Require(ShouldRequestSwapChain(request), "legacy frame-generation request remains supported");
	request.d3d12 = false;
	Require(!ShouldRequestSwapChain(request), "Vulkan must fall back for the native Step 4 scope");
	request.d3d12 = true;
	request.featureAvailable = false;
	Require(!ShouldRequestSwapChain(request), "missing device feature must fall back");
	request.featureAvailable = true;
	request.interfaceComplete = false;
	Require(!ShouldRequestSwapChain(request), "incomplete interface must fall back");

	Sequence sequence = { 1, 2, 3, 4, 5, 6, 7, 8 };
	Require(IsCompleteAndOrdered(sequence), "canonical marker sequence must pass");
	sequence.inputSample = 0;
	Require(!IsCompleteAndOrdered(sequence), "missing input marker must fail");
	sequence.inputSample = 5;
	Require(!IsCompleteAndOrdered(sequence), "input after simulation end must fail");
	sequence = { 1, 2, 3, 4, 5, 7, 6, 8 };
	Require(!IsCompleteAndOrdered(sequence), "present before submit end must fail");

	std::cout << "NRI low-latency contract tests passed\n";
	return 0;
}
