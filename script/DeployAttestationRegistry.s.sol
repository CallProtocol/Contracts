// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AttestationRegistry} from "../src/AttestationRegistry.sol";
import {VersionZero} from "./VersionZero.sol";

/// @title DeployAttestationRegistry
/// @notice Deployment `AttestationRegistry`,version 0 Writes with the construction function.
///
/// Deployment and Writing version 0It must be.**Same deal.**:Split it in two. In the middle window.
/// `attest()` To everyone. revert  -  -  That's how this door was welded to death. version 0 is the construction parameter
/// (See `AttestationRegistry` The script concludes with the statement that the door is open.
/// Otherwise, the entire deployment failed.
///
/// Full connection to the four contracts (in thousands of euros)Call / MerkleDistributor / ClearingPool With two places `setPool`)Yes.
/// [`DeploySystem.s.sol`](./DeploySystem.s.sol)(M1-3,issue #8).The script used the file.
/// `resolvePublisher` / `assertGateIsOpen` / `logRegistry` and `VersionZero`  -  -
/// **The registration form is deployed either in a script or in a script, not both.**:The registration form is one in each chain.
///
/// ```bash
/// # Local / Test net (spaced text sufficient)
/// forge script script/DeployAttestationRegistry.s.sol --rpc-url <url> --broadcast
///
/// # Main: Hash, whose text must be finalized and whose legal opinion has been signed, see legal/attestation-v0/README.md
/// ATTESTATION_V0_TERMS_HASH=0x... ATTESTATION_V0_ATTESTATION_HASH=0x... \
///   forge script script/DeployAttestationRegistry.s.sol --rpc-url robinhood --broadcast
/// ```
contract DeployAttestationRegistry is Script {
    /// @dev publisher There is only one power:**Append**Later. It can't change, it can't delete anything.
    ///      And it's not about the state of the statement -- so it's not about the trust in the system, it's about the business option.
    ///      Use the deployment itself if not filled in; as version 0 Walking to construct functions,publisher It's not the deployment that affects deployment.
    string internal constant ENV_PUBLISHER = "ATTESTATION_PUBLISHER";

    /// @dev The "Door Open" assertion at the end of the article, "The Address of the Probe." Any address that never appeared could be -
    ///      That's exactly what's not variable. 6(3) The assertion is that:**Any**The address can meet the threshold on its own.
    address internal constant GATE_PROBE = address(uint160(uint256(keccak256("index-rein: attestation gate probe"))));

    function run() external returns (AttestationRegistry registry) {
        return deploy(resolvePublisher(msg.sender));
    }

    /// @notice Parsing publisher:`ATTESTATION_PUBLISHER` First, then fall back without setting `fallbackTo`(The site is usually a deploymenter.
    ///
    /// @dev `public` And "Who to use when not set" as a parameter is made to allow M1-3 The four contracts are deployed scripts (in the form of a single contract)issue #8)Reuse it...
    ///      If you change the tone, `run()`,`msg.sender` It's gonna be...**Script contract yourself.**,publisher  And it'll be quiet
    ///      There's no private key address, and... publisher Yes. `immutable`.
    function resolvePublisher(address fallbackTo) public view returns (address publisher) {
        address configured = vm.envOr(ENV_PUBLISHER, address(0));
        // CRITICAL Clearly what value this step is.`ATTESTATION_PUBLISHER` When you have the wrong name.**Silence.**The government has been working on the issue of the "Standing Back" project.
        //    And... publisher Yes. immutable  -  -  Only one registration form was found to be redeployed late.
        console2.log(
            configured == address(0)
                ? string.concat(
                    unicode"[publisher] ", ENV_PUBLISHER, unicode" Not set, deployer:", vm.toString(fallbackTo)
                )
                : string.concat(unicode"[publisher] From ", ENV_PUBLISHER, unicode":", vm.toString(configured))
        );
        return configured == address(0) ? fallbackTo : configured;
    }

    function deploy(address publisher) public returns (AttestationRegistry registry) {
        VersionZero.Texts memory v0 = VersionZero.load();
        VersionZero.requireDeployable(v0);

        vm.startBroadcast();
        registry = new AttestationRegistry(publisher, v0.termsHash, v0.attestationHash);
        vm.stopBroadcast();

        assertGateIsOpen(registry, v0);
        logRegistry(registry, publisher, v0);
    }

    /// @notice Verify non-variables as soon as deployed 6(3) The premise is that the chain is set:`versions[0]` The two texts just now,
    ///         And one.**Address never showed up.**It's a real deal. `attest(0, ...)` Pass the threshold.
    ///
    /// @dev This is a local simulation. `broadcast` Inside, so no transactions will be made...
    ///      It runs the byte code that just deployed, and it says, "This byte code is open."
    ///      The source code seems to be open.
    ///
    ///      `public` It's for the sake of... M1-3 The four contract scripts (of the`DeploySystem.s.sol`)The same claim is repeated:
    ///      There must be.**My own part. broadcast Lee.**Create registration form (multiparts) broadcast Will let forge - Put it on. nonce The blogger adds:
    ///      The only thing that can be used again is the knowledge of how to calculate text and how to print it.
    function assertGateIsOpen(AttestationRegistry registry, VersionZero.Texts memory v0) public {
        require(
            registry.versionCount() == 1,
            unicode"After deployment versions - It's not. 1  -  -  version 0 It's not in the paper."
        );

        (bytes32 termsHash, bytes32 attestationHash) = registry.versions(0);
        require(termsHash == v0.termsHash, unicode"The chain. termsHash It's not consistent with the file.");
        require(
            attestationHash == v0.attestationHash,
            unicode"The chain. attestationHash It's not consistent with the file."
        );

        vm.prank(GATE_PROBE);
        registry.attest(0, v0.termsHash, v0.attestationHash);
        require(
            registry.attestedVersion(GATE_PROBE) == 1,
            unicode"Door open: Strange address. attest(0, ...) The threshold was not passed since then."
        );
    }

    /// @notice Deployment log for the registration section.
    /// @dev CRITICAL CI Li'l Z'version 0 "Hashi can recalculate."**Parse this output by line**..of the`termsHash` / `attestationHash`
    ///      Second column of two rows. `.github/workflows/ci.yml`.
    ///      `public` It's the same. `DeploySystem.s.sol` Reuse - Both scripts must print the same registration form information.
    function logRegistry(AttestationRegistry registry, address publisher, VersionZero.Texts memory v0) public pure {
        console2.log(
            string.concat(
                "[AttestationRegistry] ",
                vm.toString(address(registry)),
                "\n  publisher       ",
                vm.toString(publisher),
                "\n  termsHash       ",
                vm.toString(v0.termsHash),
                "\n  attestationHash ",
                vm.toString(v0.attestationHash),
                VersionZero.isDraft(v0) ? unicode"\n  WARNING Placed text (draft), only testing network" : ""
            )
        );
    }
}
