// Copyright (c) 2026 Todd Austin.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// License: https://polyformproject.org/licenses/noncommercial/1.0.0/

// Actual R05 configuration/SHA/source/time, R06 lease/quorum and R07 SPI/memory.
// Only signature computation is software, over actual fresh sealed-memory reads.
#define DOCTEST_CONFIG_IMPLEMENT
#include <doctest/doctest.h>
#include "Vr07_integration_top.h"
#include "reins/r07_test_support.h"
using namespace reins::sim;
using namespace reins::sim::reference;
using namespace reins::sim::r06_test;
using namespace reins::sim::r07_test;
using Integration=PinBench<Vr07_integration_top>;
namespace {
// Return independently signed keys under a timing profile allowing complete pin-level ARM/RENEW uploads.
Corpus& records() { static Corpus result({8'000'000,3'000'000,2'500'000}); return result; }
}

// Exercise ARM/RENEW with real conditioner outputs and withdraw permission during active SPI on a sensor alarm.
TEST_CASE("R07 integration: real R05 startup, pin-level ARM and RENEW, live sensor fail-off") {
    Integration bench(records()); CHECK(bench.read(1)[3]==2); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(0); bench.verify(); CHECK_FALSE(bench.dut.permit_o);
    bench.upload(1); bench.verify(); REQUIRE(bench.dut.permit_o); CHECK(bench.dut.lease_expiry_o==8'000'000);
    while (!bench.dut.request_valid_o) bench.idle(16);
    REQUIRE(bench.dut.round_o==2); const auto request=bench.read(0x10,2); CHECK(request[5]==3);
    bench.upload(1); bench.verify(); bench.upload(2); bench.verify();
    REQUIRE(bench.dut.permit_o); CHECK(bench.dut.lease_expiry_o==11'000'000);
    bench.pins.select(); bench.pins.bits(1,8); bench.dut.sensor_healthy_i=0; bench.settle();
    CHECK_FALSE(bench.dut.permit_o); bench.idle(2); CHECK(bench.dut.fault_o);
    bench.reference.alarm("sensor alarm during SPI"); bench.model_enabled=false; bench.pins.deselect();
    CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.job_active_o);
}

// Confirm host traffic cannot change closed OTP and a reset cancels an unfinished receive without granting permission.
TEST_CASE("R07 integration: closed OTP and warm reset during a receive transaction") {
    Integration bench(records()); const auto original=unpack(bench.dut.configuration_o,272);
    const auto token=bench.begin(2); bench.chunk(2,token,0,Bytes(64,0x5a));
    bench.dut.config_address_i=1; bench.dut.config_data_i=0xff; bench.dut.config_write_i=1; bench.idle(1);
    CHECK_FALSE(bench.dut.config_write_accepted_o); bench.dut.config_write_i=0;
    CHECK(unpack(bench.dut.configuration_o,272)==original);
    bench.model_enabled=false; bench.dut.warm_reset_i=1; bench.settle(); CHECK_FALSE(bench.dut.permit_o); bench.idle(2);
    bench.dut.warm_reset_i=0; bench.idle(4); CHECK_FALSE(bench.dut.receive_owned_o); CHECK_FALSE(bench.dut.job_active_o);
    CHECK_FALSE(bench.dut.permit_o); CHECK_FALSE(bench.dut.config_valid_o);
    bench.reference.reset(Reset::warm); bench.oracle.reset(); bench.reference_started=false; bench.published_round=0;
    bench.model_enabled=true; bench.startup();
    CHECK(bench.dut.config_valid_o); CHECK(unpack(bench.dut.configuration_o,272)==original);
    const auto fresh_token=bench.begin(2); CHECK(fresh_token>token);
    CHECK(bench.exchange(spi_frame(0x21,2,chunk_data(token,0,Bytes(64,0x5a)))).back()==6);
}

// Run argc/argv's actual-platform cases and retain their full input/output/coverage evidence.
int main(int argc, char** argv) { return run(argc,argv,"rtl-r07-platform"); }
