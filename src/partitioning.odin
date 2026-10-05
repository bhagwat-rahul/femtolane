package main

// partition design hierarchically for organisational boundaries + running computations on partitions for speed
// this can probably just partition the hypergraph created by the gl netlist? or in later stages even partition by placement region etc.
// another benefit or partitioning is for chiplet based architectures, where different sections may use entirely different PDKs, it is valuable to simulate these blocks together.
// NOTE(rahul): PDK shouldn't be global within a running instance, since different designs that you may be working on at the same time may have different PDKs associated with them, both the logical and gui model needs to allow this seamlessly and chiplet + multi-die stuff / packaging should have first class support
