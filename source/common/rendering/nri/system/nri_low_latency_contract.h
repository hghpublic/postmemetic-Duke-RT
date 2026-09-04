#pragma once

#include <cstdint>

namespace nri_low_latency_contract
{
	struct SwapChainRequest
	{
		bool nativeRequested = false;
		bool frameGenerationRequested = false;
		bool d3d12 = false;
		bool deviceAvailable = false;
		bool swapChainInterfaceAvailable = false;
		bool featureAvailable = false;
		bool interfaceComplete = false;
	};

	inline bool ShouldRequestSwapChain(const SwapChainRequest& request)
	{
		return
			(request.nativeRequested || request.frameGenerationRequested) &&
			request.d3d12 &&
			request.deviceAvailable &&
			request.swapChainInterfaceAvailable &&
			request.featureAvailable &&
			request.interfaceComplete;
	}

	struct Sequence
	{
		uint64_t sleep = 0;
		uint64_t simulationStart = 0;
		uint64_t inputSample = 0;
		uint64_t simulationEnd = 0;
		uint64_t renderSubmitStart = 0;
		uint64_t renderSubmitEnd = 0;
		uint64_t presentStart = 0;
		uint64_t presentEnd = 0;
	};

	inline bool IsCompleteAndOrdered(const Sequence& sequence)
	{
		return
			sequence.sleep != 0 &&
			sequence.sleep < sequence.simulationStart &&
			sequence.simulationStart < sequence.inputSample &&
			sequence.inputSample < sequence.simulationEnd &&
			sequence.simulationEnd < sequence.renderSubmitStart &&
			sequence.renderSubmitStart < sequence.renderSubmitEnd &&
			sequence.renderSubmitEnd < sequence.presentStart &&
			sequence.presentStart < sequence.presentEnd;
	}
}
