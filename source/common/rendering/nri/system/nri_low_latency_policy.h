#pragma once

#include "nri_local.h"

#include <cstdint>

class NRIRenderDevice;

struct NRILowLatencyState
{
	bool requested = false;
	bool interfaceAvailable = false;
	bool featureAvailable = false;
	bool swapChainEnabled = false;
	bool operational = false;
	bool sleepModeConfigured = false;
	bool sleepInvoked = false;
	bool inputSampleMarked = false;
	bool presentBoundarySeen = false;
	bool contractValid = false;
	bool simulationActive = false;
	bool submitSucceeded = false;
	bool submitAssociated = false;
	bool presentSucceeded = false;
	bool reportChanged = false;
	bool reportAllZero = true;
	bool runtimeSuppressed = false;
	const char* runtimeFailure = "none";
	uint64_t presentationGeneration = 0;
	uint64_t sequence = 0;
	uint64_t sleepOrder = 0;
	uint64_t simulationStartOrder = 0;
	uint64_t inputSampleOrder = 0;
	uint64_t simulationEndOrder = 0;
	uint64_t renderSubmitStartOrder = 0;
	uint64_t renderSubmitEndOrder = 0;
	uint64_t presentStartOrder = 0;
	uint64_t presentEndOrder = 0;
	uint64_t latencySleepCount = 0;
	uint64_t markerCount = 0;
	uint64_t completeContractCount = 0;
	uint64_t duplicateInputSampleCount = 0;
	uint64_t abortedTransactionCount = 0;
	const char* lastAbortReason = "none";
	uint64_t latencySleepUs = 0;
	nri::LatencySleepMode configuredSleepMode = {};
	nri::Result setSleepModeResult = nri::Result::FAILURE;
	nri::Result latencySleepResult = nri::Result::FAILURE;
	nri::Result simulationStartMarkerResult = nri::Result::FAILURE;
	nri::Result inputSampleMarkerResult = nri::Result::FAILURE;
	nri::Result simulationEndMarkerResult = nri::Result::FAILURE;
	nri::Result renderSubmitStartMarkerResult = nri::Result::FAILURE;
	nri::Result renderSubmitEndMarkerResult = nri::Result::FAILURE;
	nri::Result latencyReportResult = nri::Result::FAILURE;
	nri::Result runtimeDisableResult = nri::Result::FAILURE;
	nri::LatencyReport latencyReport = {};
};

class NRILowLatencyPolicy
{
public:
	bool ShouldRequestSwapChain(const NRIRenderDevice& frameBuffer) const;
	void OnSwapChainCreated(const NRIRenderDevice& frameBuffer);
	void OnSwapChainDestroyed(const NRIRenderDevice& frameBuffer);
	void BeginSimulation(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration);
	void MarkInputSample(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration);
	void EndSimulation(const NRIRenderDevice& frameBuffer, uint64_t presentationGeneration);
	void OnRenderSubmitStart(const NRIRenderDevice& frameBuffer, bool submitAssociated);
	void OnRenderSubmitEnd(const NRIRenderDevice& frameBuffer, nri::Result submitResult);
	void OnPresentStart(const NRIRenderDevice& frameBuffer);
	void OnPresentEnd(const NRIRenderDevice& frameBuffer, nri::Result presentResult);

	const NRILowLatencyState& GetState() const { return mState; }

private:
	bool IsOperational(const NRIRenderDevice& frameBuffer) const;
	void RefreshAvailability(const NRIRenderDevice& frameBuffer);
	void ConfigureSleepMode(const NRIRenderDevice& frameBuffer);
	void SetMarker(
		const NRIRenderDevice& frameBuffer,
		nri::LatencyMarker marker,
		nri::Result& result,
		uint64_t& order,
		const char* failureStage);
	void SuppressRuntime(const NRIRenderDevice& frameBuffer, const char* failureStage);
	void ResetFrameState(uint64_t presentationGeneration);
	void UpdateContractValidity();
	bool HasCompleteSimulationPrefix() const;

	NRILowLatencyState mState = {};
	nri::LatencyReport mLastLatencyReport = {};
	bool mHasLastLatencyReport = false;
};
