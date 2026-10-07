// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {console2} from "forge-std/Test.sol";

import {VaultRegistry} from "../../src/VaultRegistry.sol";
import {VaultFactoryProbe} from "../helpers/VaultFactoryProbe.sol";
import {FlapLaunchTest, IFlapVaultPortal, NewTokenV6WithVaultParams} from "./FlapLaunch.sol";
import {ForkConfig, ForkTarget} from "./ForkConfig.sol";

/// @title RobinhoodVaultIdentityForkTest
/// @notice CRITICAL **issue #23 The Court's decision 1 / 2 / 5:Programme A Can't it be real? Flap Stand up.**
///
/// The judgement 3 / 4(Tie one-time,`vaultOf` Never revert)It's about the nature of our own contract. We don't need a cross.
/// Yes. `test/VaultRegistry.t.sol`.The judgement 6 It's... factory Sidelink at the end of this document - it's going to**The fork on the real chain.**
/// Go over it, because the point of order is to get the plant in. Portal . The complete double-train ring is by
/// `test/DeploySystem.t.sol` Overwrite.
///
/// # The one that this document is about to prove.
///
/// > Real. `VaultPortal.newTokenV6WithVault(..., vaultFactory = Our factory.)` The government is not going to let us go.
/// > And we can get it at that moment.**Trustable** `(memeToken, vault)` Tie.
///
/// The word "credible" has content, not "Portal "The rule is to say:
///
/// - Turn back that moment. `taxToken` **No byte code yet.**  -  -  The bank was created before the coin.Portal The one who gave us the order.
///   CREATE2 Forecast Address (Present){test_theVaultIsCreatedBeforeTheToken} I measured it. So, "Go ask the token."
///   This road doesn't exist at all.
/// - The only thing that can be trusted is that it's from the people who are in the world.**Atomicity of the same deal**:Portal After the tokens are deployed, we'll check if it equals
///   The address we gave us, it didn't wait. `TokenAddressMismatch()` Whole roll back.
///   Deal success  The real token is bound.**We wrote that the binding and the existence of the tokens were co-inhabited.**
///
/// This argument and "convinced" Portal "The correct argument" is different, so we're going to take two separate things:
/// {test_launchBindsTheRealToken} The binding of the certificate's successful path does point to the real coin, but the evidence is not the same as the original.
/// {test_ourRegistryAgreesWithTheChain} The independent facts on the chain (in the form of the "C")Portal Your share. `tryGetVault`)Review it.
///
/// @dev Source and all physical orders:`docs/research/flap-vault-identity-spike.md`.
///      Fire the machine.27 Field parameters,vanity salt - Resolved, limited frequency circumvented. {FlapLaunchTest}  -  -
///      M2-5(issue #37)And then it had a second user.`RobinhoodCallVaultFactory.t.sol`),
///      This exact value should have only one source.**The present document has not moved a single assertion.**
contract RobinhoodVaultIdentityForkTest is FlapLaunchTest {
    VaultFactoryProbe internal factory;
    VaultRegistry internal registry;

    address internal launcher = makeAddr("project launcher");

    function setUp() public {
        // The probe landed. VaultPortal Up... that height has no status, to ask on contracts that are really going to be read.
        ForkTarget memory target = ForkConfig.robinhood();
        target.probe = VAULT_PORTAL;
        selectFork(target);

        // Only the verdict. 6 It's... factory Side path:factory + PendingLauncherSlot -> Double registry ->
        // factory.setRegistry() .No deployment here. pool,I don't know. pendingSlot.setRegistry() ;Full double-train connection
        // And locked to death. DeploySystem Test coverage.
        factory = new VaultFactoryProbe();
        registry = new VaultRegistry(address(factory));
        factory.setRegistry(registry);

        vm.deal(launcher, 10 ether);
    }

    //  Pre-position: The two real contracts were running on the fork.

    /// @dev - I'll prove it before I say anything.**It's a real contract.**.Flap This one will be red first when it's realized.
    function test_theVaultPortalIsReal() public view {
        assertGt(VAULT_PORTAL.code.length, 0, unicode"VaultPortal There should be bytes.");
        assertGt(PORTAL.code.length, 0, unicode"Portal There should be bytes.");
        assertGt(TAX_TOKEN_V3_IMPL.code.length, 0, unicode"TaxTokenV3 Bytes should be used to achieve this");

        // CRITICAL Two. Portal Not the same contract -- this is the one that's the easiest to get wrong.
        assertTrue(VAULT_PORTAL != PORTAL, unicode"VaultPortal and Portal It has to be two addresses.");

        console2.log(string.concat("  vaultPortal=", vm.toString(VAULT_PORTAL), "  portal=", vm.toString(PORTAL)));
    }

    //  The judgement 1:Portal We're really retraced and tied up.

    /// @notice CRITICAL **The judgement 1 The body.**
    function test_launchBindsTheRealToken() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        VaultFactoryProbe.Recorded memory r = factory.last();

        assertEq(factory.callCount(), 1, unicode"The factory should be transferred back exactly once.");
        assertEq(r.taxToken, token, unicode"The address we get on the call must be the last token that was built.");
        assertGt(token.code.length, 0, unicode"The token should have been deployed at the end of the transaction.");
        assertEq(registry.vaultOf(token), r.vault, unicode"The identity must be the vault we built.");

        console2.log(
            string.concat(
                unicode"  -> token=",
                vm.toString(token),
                "  vault=",
                vm.toString(r.vault),
                "  creator=",
                vm.toString(r.creator)
            )
        );
    }

    /// @notice CRITICAL **Our factory is not here. VaultPortal Registered and the launch was successful.**
    ///
    /// @dev This one ends with Flap One in the document**The three parties are in conflict.**(`docs/research/flap-vault-identity-spike.md` 6):
    ///      The standard page and the quick start say "No plant needs to be registered" and VaultPortal The launch guide says, "Select one."**Registered**The blog is a blog post of the blog.
    ///      It's still in the interface. `registerVaultFactory(...)` and `error VaultFactoryNotRegistered(address)`
    ///      (Both are in bytes of deployment in this chain.
    ///
    ///      It doesn't matter what the document is arguing about -- running through the fork is the answer:**Unregistered and unstopped.**,
    ///      Registering only affects Flap From front end `riskLevel` / `official` Such markings.
    ///      If this thing turns around, it's a plan. A And then it turns to "Yes." Flap Nod your head. That's the verdict. 1 The blogger says that the government is not responsible for the crime.
    ///      So it has to be a red-red test, not a sentence in the document.
    function test_ourFactoryIsNotRegisteredYetTheLaunchSucceeds() public {
        (bool enabled, bool official, uint8 riskLevel,) = vaultPortal.vaultFactories(address(factory));

        assertFalse(enabled, unicode"Pre-position: Our factory shouldn't have been registered.");
        assertFalse(official, unicode"Prefix: Not to mention official");
        assertEq(riskLevel, 0, unicode"Prefix:riskLevel For UNVERIFIED");

        address token = _launch(_params(address(factory), _mineVanitySalt()));

        assertEq(registry.vaultOf(token), factory.last().vault, unicode"Unregistered factories are tied up.");
    }

    /// @notice CRITICAL **The judgement 1 The whole basis of the word "trusted" in the paper.**:The return moment does not yet exist.
    ///
    /// @dev Once this is true, any design for "checking points on tokens when you're back" is empty.
    ///      It limits the source of credibility to the same atomicity of the transaction -- and that's it.**Structure**Promise, not a presumption of trust.
    function test_theVaultIsCreatedBeforeTheToken() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        VaultFactoryProbe.Recorded memory r = factory.last();

        assertEq(r.taxTokenCodeSize, 0, unicode"Turn back that moment. taxToken There should be no byte code.");
        assertGt(r.taxToken.code.length, 0, unicode"But it must exist after the deal is over.");
    }

    /// @notice Reverted. `msg.sender` Yes. **VaultPortal**,No, it's not. Portal.
    ///
    /// @dev CRITICAL This one determines which address the door is to be pinned to. Wrong. = The first time I was in the business, I was not able to get a series of them.
    ///      And it's a... `immutable`,It's not gonna change.
    function test_theCallerIsTheVaultPortalNotThePortal() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        assertEq(factory.last().caller, VAULT_PORTAL, unicode"newVault Caller for");
        assertTrue(factory.last().caller != PORTAL, unicode"No, it's not. Portal");
    }

    /// @notice The independent facts of the chain review our binding:Portal I wrote one down myself. `token -> vault`.
    ///
    /// @dev WARNING Here.**No, it's not.**We believe in it. Portal The record -- it lives in one. Flap The government has been working on the issue of the Internet.
    ///      It's the reason why the root of identity should be independent. It's just what it is.**Second observer**:The two records are not right.
    ///      It shows that there is a hole in our understanding of this process.
    function test_ourRegistryAgreesWithTheChain() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        (bool found, IFlapVaultPortal.VaultInfo memory info) = vaultPortal.tryGetVault(token);

        assertTrue(found, unicode"Portal The side should also write down the vault of the coin.");
        assertEq(info.vault, registry.vaultOf(token), unicode"Both records must point to the same vault.");
        assertEq(info.vaultFactory, address(factory), unicode"Portal The factory should be us.");
    }

    //  Why must the root be our own?

    /// @notice CRITICAL **Flap That one. `token -> vault` It can be rewrited and has already been rewrited.**
    ///
    /// @dev This one doesn't belong to any of the six statutes, but it is.**Reason for the entire layer structure**,So nailed here:
    ///
    ///      VaultPortal I'm gonna keep one of them. `token -> vault`({IFlapVaultPortal-getVault}).
    ///      Read it and you don't have to build the pool. registry Yeah, it looks like it's a little bit of a relief.
    ///      `refreshTokenVault(address)`,`AUDITOR_ROLE` It's a truncable effect.**Redo**The binding;
    ///      There's been a change in the chain history twice.
    ///      (`docs/research/flap-vault-identity-spike.md` 7).
    ///
    ///      That means, "Get the authorization door to the pool." Flap That's the same thing that says, "Who can give to someone?" MEME "The Caster."
    ///      Give it to a character we can't control.**This is all the reason why identity is independent and immutable.**
    ///
    ///      Here's only proof that the rewritten path exists and that the role alone is the door -- we can't lift it. `AUDITOR_ROLE` the holder,
    ///      So, I can't prove "who can push that switch." I can only prove it.**Switches in**.and `ForkConfig` Lee. mock Drop it.
    ///      Robinhood Door control. view The alternative is the same structure:mock Instead of "who pressed the switch," it was "what happens when you press it."
    function test_flapsOwnBindingIsRewritableWhereasOursIsNot() public {
        address token = _launch(_params(address(factory), _mineVanitySalt()));

        // Rewrite path exists and is blocked by the role - not "This function does not exist".
        vm.prank(makeAddr("not an auditor"));
        (bool ok, bytes memory ret) = VAULT_PORTAL.call(abi.encodeCall(IFlapVaultPortal.refreshTokenVault, (token)));
        assertFalse(
            ok,
            unicode"Strange addresses should not be changed -- but the reason it was rejected was that it was a very good idea to be a good person.**No character.**"
        );
        assertGt(
            ret.length, 0, unicode"I should have it with me. AccessControl The reason is rejected, not \"no function.\""
        );

        // We have no corresponding entry to reject -- there is no second function in writing the face count.
        // The structure is proving to be... `test/VaultRegistry.t.sol::test_writeSurface_isExactlyOneFunction`.
        assertEq(registry.vaultOf(token), factory.last().vault, unicode"We're not moving.");
    }

    //  The judgement 2:Limited access to registration (separate evidence of one negative vote)

    /// @notice CRITICAL **The judgement 2 Half the fork.**:Anyone can build a coin, but...**It's not gonna make a vault for any other man's money.**.
    ///
    /// @dev The judgement 2 The real thing to do is to put a "soldier down." It's a two-pronged project:
    ///      (1) The factory only recognizes it. VaultPortal((a) This article;
    ///      (2) The root of identity only recognizes the factory and every one of them. MEME It's only one time.
    ///         (`test/VaultRegistry.t.sol`,No fork.
    ///
    ///      Together: a binding can only be born inPortal The moment when the coin was created, the people were not aware of the need to create it.
    ///      And that moment the tokens didn't exist... **One already exists. MEME,No one can ever give it any more access to the register.**
    ///      The bets are not "harder" for that.**There's no entrance.**.
    function test_nobodyCanCallNewVaultExceptTheVaultPortal() public {
        address[3] memory strangers = [launcher, PORTAL, address(this)];

        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.OnlyVaultPortal.selector, strangers[i]));
            factory.newVault(makeAddr("victim MEME"), address(0), strangers[i], "");
        }

        assertEq(factory.callCount(), 0, unicode"You shouldn't have walked in there once.");
        assertEq(registry.vaultOf(makeAddr("victim MEME")), address(0), unicode"And not to leave any binding.");
    }

    /// @notice Even if the bet-raider actually sent a coin, he'd just get it.**His own.**The vault.
    ///
    /// @dev This is the verdict. 2 And the positive expression, it's the same.**Border**Note:
    ///
    ///      CRITICAL `msg.sender == VaultPortal` The one that's blocking it is.**Caller**,No, it's not.**Sponsor**.Any stranger. EOA
    ///      I can make it real. VaultPortal,Fill our factory in the parameters, so it's ours. `newVault` I'll take it.
    ///      **The attackers chose it. `vaultData`,The assailant. `creator`** Run it again. The factory is therefore a public facility...
    ///      This is what the unlicensed launch model should be for, not a loophole.
    ///
    ///      The judgement 2 Another question:**The government has also been able to register the "others', already existing" coins.** No, I can't.
    ///      And the reason is structural -- binding is only born in the "Portal The moment when the coin was created, the people were not aware of the need to create it.
    ///      The coins didn't exist at that moment.{test_theVaultIsCreatedBeforeTheToken}),There will be no further entrances thereafter.
    ///
    ///      WARNING But there's one in "the factory is a public facility."**- I'll leave it to you. #33 It's...**Constraints: Treasury templates must be controlled by enemy hands
    ///      `vaultData` and `creator` It's still safe. The check doesn't work out, just write it down.
    function test_anAttackerOnlyEverBindsTheirOwnToken() public {
        address victim = _launch(_params(address(factory), _mineVanitySalt()));
        address victimVault = registry.vaultOf(victim);

        // The attackers sent one of them. They used the same factory.
        address attackerToken =
            _launch(_params(address(factory), _mineVanitySaltFrom(uint256(keccak256("attacker")) % 1e6)));
        VaultFactoryProbe.Recorded memory r = factory.last();

        assertTrue(attackerToken != victim, unicode"The two tokens should be different.");
        assertEq(registry.vaultOf(victim), victimVault, unicode"The victim should not have moved a single byte.");
        assertTrue(registry.vaultOf(attackerToken) != victimVault, unicode"The attackers have their own vault.");

        // `creator` The strange sponsor -- write this down, it's the basis of the border that's above.
        assertTrue(r.creator != address(this), unicode"creator It's the sponsors, not us.");
        assertEq(r.taxToken, attackerToken, unicode"And only his own.");
    }

    //  The judgement 5:Flap Change it. Portal What happens after that?

    /// @notice CRITICAL **The judgement 5**:After the change of address**New project slotting, bound without impact**,The government has not yet done so.
    ///
    /// @dev Flap Change it. PortalThere are two types of reality, with completely different consequences, so we say separately:
    ///
    ///      | Form | Consequences |
    ///      |---|---|
    ///      | Upgrade Agent**The Realization Behind**(`0xe9F7...` No change) | We're on our way.**Nothing.**  -  -  The door was locked to the proxy address. |
    ///      | Deployment**New** VaultPortal(New address) Old disabled | New project is out of range. We need to redeploy a plant. |
    ///
    ///      This article is the second test. Two things must be established in order to be "contributable":
    ///      (1) Customise bound items... `vaultOf` It's pure. storage Read, with Portal Not relevant;
    ///      (2) Disconnect**It's not quiet.**  -  -  Old entrance pen. revert,New Portal I can't get into our factory.
    ///        (The latter is by {test_afterTheMove_aNewPortalStillCannotRegister} Single nails.
    ///
    ///      CRITICAL Disable `vm.etch(..., hex"fe")`(INVALID)Not `hex"00"`:`0x00` Yes. `STOP`,
    ///      Call it will.**Success**And back empty -- that's exactly the silent shape this article is supposed to exclude, and treat it as a model to disable.
    ///      And it's gonna make it happen.
    function test_whenFlapMovesThePortal_boundProjectsSurvive_newOnesFailLoudly() public {
        address bound = _launch(_params(address(factory), _mineVanitySalt()));
        address boundVault = registry.vaultOf(bound);
        assertTrue(boundVault != address(0), unicode"Prefix: This one should be tied.");

        // Flap Move out. Old entrance is disabled.
        vm.etch(VAULT_PORTAL, hex"fe");

        // (1) We can read it as we know it.
        assertEq(registry.vaultOf(bound), boundVault, unicode"The bound items must be unaffected.");

        // (2) New project: failed to launch the whole text from the old address, and will not be tied silently elsewhere
        address who = _freshLauncher();
        vm.prank(who, who);
        (bool ok,) = VAULT_PORTAL.call(
            abi.encodeCall(
                IFlapVaultPortal.newTokenV6WithVault, (_params(address(factory), _mineVanitySaltFrom(700_001)))
            )
        );
        assertFalse(ok, unicode"Portal Launch from old address must fail after disablement");

        assertEq(factory.callCount(), 1, unicode"The factory should not be retraced for the second time.");
    }

    /// @notice After the change of address, even if someone was looking at the new one, Portal I'm not gonna get in here.
    /// @dev This is the other half of the "failure signal clear": not "change it." Portal The blogger says that the government is not going to be able to get the money.
    ///      It's about having to.**Reposition one plant.**(The constant changes, the existing bindings follow the old ones. registry As it is.
    function test_afterTheMove_aNewPortalStillCannotRegister() public {
        address newPortal = makeAddr("Flap's next VaultPortal");

        vm.prank(newPortal);
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.OnlyVaultPortal.selector, newPortal));
        factory.newVault(makeAddr("some MEME"), address(0), newPortal, "");
    }

    //  The judgement 6:factory The sidelink is locked.

    /// @notice CRITICAL **The judgement 6 It's... factory Side**:`factory` + `PendingLauncherSlot` -> Double `VaultRegistry` ->
    ///         `factory.setRegistry()`,And the factory's one-off slot is locked.
    ///
    /// @dev `setUp` It's been done in this minimum order. factory Yes. registry
    ///      on the List and `setRegistry` The one-time slot is locked; the preset connection and the locked death route DeploySystem Tests are verified separately.
    function test_theFactorySideOfTheIdentityRootIsWiredAndLocked() public {
        assertTrue(registry.isFactory(address(factory)), unicode"This factory is on the list.");
        assertEq(address(factory.registry()), address(registry), "factory.registry");

        // One time: the deploying will not change itself for the second time
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.RegistryAlreadySet.selector, address(registry)));
        factory.setRegistry(VaultRegistry(makeAddr("another registry")));

        // Robbing: Not even for non-deployed
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(VaultFactoryProbe.NotDeployer.selector, launcher));
        factory.setRegistry(VaultRegistry(makeAddr("hijacked registry")));

        assertEq(
            address(factory.registry()),
            address(registry),
            unicode"Those two attempts should not have changed anything."
        );
    }

    /// @notice And write it down. Portal Which of our plants were transferred during the launch?**Not achieved**The choicer.
    /// @dev "Singing them silent means right."Flap "The necessary new hooks are blinded" -- the first time that change came up.
    ///      Most of them are optional, and it's too late when it becomes necessary.
    function test_reportUnknownSelectorsThePortalProbed() public {
        _launch(_params(address(factory), _mineVanitySalt()));

        bytes4[] memory unknown = factory.unknownSelectors();
        for (uint256 i = 0; i < unknown.length; i++) {
            console2.log(string.concat(unicode"  Portal And they detected:", vm.toString(unknown[i])));
        }
        console2.log(string.concat(unicode"  Unrealised Selector ", vm.toString(unknown.length), unicode" individual"));
    }
}
