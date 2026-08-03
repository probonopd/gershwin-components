#ifndef GSUTMConstants_h
#define GSUTMConstants_h

typedef NS_ENUM(NSInteger, GSUTMArchitecture) {
    GSUTMArchitectureX86_64,
    GSUTMArchitectureAArch64,
};

typedef NS_ENUM(NSInteger, GSUTMMachineTarget) {
    GSUTMMachineTargetQ35,
    GSUTMMachineTargetPC,
    GSUTMMachineTargetVirt,
};

typedef NS_ENUM(NSInteger, GSUTMMachineState) {
    GSUTMMachineStateStopped,
    GSUTMMachineStateStarting,
    GSUTMMachineStateStarted,
    GSUTMMachineStateStopping,
    GSUTMMachineStateError,
};

extern NSString *const GSUTMErrorDomain;

#endif
