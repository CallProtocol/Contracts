// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ReentrancyInjector} from "./ReentrancyInjector.sol";

/// @title StockToken
/// @notice A double for collateral (currencyization stocks).**This is an externally dependent double, not our own contract. mock**
///          -  -  issue #5 The latter is only prohibited by the test discipline.
///
/// It's meant to have three real things and one "be honest." ERC-20Not of a nature:
///
/// | Nature | It makes any claim meaningful. |
/// |---|---|
/// | **Transfer tax**(`taxBps`) | "As a result of the actual increase in the amount of the account, it is not the amount requested." |
/// | **`uiMultiplier()`** | Use all quantities raw `balanceOf` Unit - The unit is changed by this number, not by the balance. |
/// | Any `mint` | uint128 Border: Real GME I can't make it. 2^128,But the pool is right.**Any**The stock is on. |
///
/// CRITICAL Tax model by**Less receipt by the recipient**Modelling (`transfer(x)` later recipients `+xfee`),That's exactly what I'm talking about.
/// `depositAndMint` The one that's gonna step on: press. `expectedAmount` The casting is tantamount to a multiple certificate of authority.
///
/// @dev Real GME Door Control (`pause` / `isBlocked` / `adminBurn`)**Not here to simulate.**  -  -
///      The only real contracts on the fork are right. See. `test/fork/RobinhoodExercise.t.sol`(issue #10)
///      Extension of full path with door control (issue #11).Let's get "D" 3 The incident took place locally with certainty, and the government has not yet been able to provide any information on the situation.
///      Use {GatedStockToken},It's...**Failed Injection**The project is not a door-control semantic model.
contract StockToken is ERC20 {
    /// @notice Taxes go. Real currency is mostly a treasury;It's all we're asking for here.**Not the pool.**.
    address public constant TAX_SINK = address(uint160(uint256(keccak256("index-rein: tax sink"))));

    /// @notice Transfer tax, ten thousand.0 = - Nice coin.
    uint16 public taxBps;

    /// @notice EIP-8056 Shows the multiplier. The split is it.**No, it's not. `balanceOf`**.
    /// @dev The pool should not have read this number from beginning to end. It exists here to make "what if read" a certain fact.
    uint256 public uiMultiplier = 1e18;

    constructor() ERC20("Tokenized Stock", "STOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxBps(uint16 bps) external {
        require(bps <= 10_000, "tax > 100%");
        taxBps = bps;
    }

    function setUiMultiplier(uint256 multiplier) external {
        uiMultiplier = multiplier;
    }

    /// @dev Casting ()`from == 0`)and destruction (`to == 0`)No taxes - collection would have been a bad match for the initial balance of the test.
    ///      And that's not any real token act.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (taxBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * taxBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee != 0) super._update(from, TAX_SINK, fee);
    }
}

/// @title GatedStockToken
/// @notice Leave the right. 3 Step (share tokens transferred to beneficiaries)**Uncertainty failure**The injection.
///
/// CRITICAL **It's not. GME The door control model.** The real door control is "In the register." `isBlocked(I'm a pool.)`Double `paused()`,
/// Semantics,revert The data, the impact, the real contract on the fork.
/// `test/fork/RobinhoodExercise.t.sol` The thing, it... mock It's the registration form. It's still going. GME Your own decorator.
///
/// All we need is one thing: to get the last call from the outside.**Failed**,Well, I'm sure it's not a variable. 3(Either substep failed  Certificates and MEME
/// The balance is unchanged. The non-variant test cannot rely on the network, so this must happen locally.
///
/// @dev The casting and destruction are not affected - otherwise, the initial balance of testing itself cannot be put out during the freeze.
contract GatedStockToken is StockToken {
    /// @notice The information is being frozen. The real world is the equivalent of "pool addresses sealed" or "coin suspended".
    bool public frozen;

    error IssuerFrozen();

    function setFrozen(bool frozen_) external {
        frozen = frozen_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen && from != address(0) && to != address(0)) revert IssuerFrozen();
        super._update(from, to, value);
    }
}

/// @notice ERC-20 Call Back `true`,However, the transfer phase could be deliberately carried out without changing any balance.
/// @dev First, you put the collateral in, then you turn on the switch, and you only attack the dependencies. `transferFrom` The path to a successful return.
contract NoOpStockToken is StockToken {
    bool public noOpTransfers;

    function setNoOpTransfers(bool enabled) external {
        noOpTransfers = enabled;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (noOpTransfers && from != address(0) && to != address(0)) return;
        super._update(from, to, value);
    }
}

/// @notice ERC-20 Call Back `true`,But only one of the requests is moved.**Quota**  -  -  The government has also been making a number of efforts to reduce the cost of the project.
///
/// @dev It's... {NoOpStockToken}(The split of the vault is the same as the entire stale stub between the real coin.
///      If you press the book,**Request Volume**Not**Deductions measured**The check-in is a token that allows the same income to be retested.
///      Repeated splitting (audit findings) M-01) -  -  The same thing as a fake transfer agent: the truth is that the money doesn't prove this discipline.
///      `setHalfDebit` Keep As 50% The easy switch in that set; go on a random scale `setDebitBps`
///      (10000 = The full amount,0 = Equivalent to {NoOpStockToken}),Top bounds for Random Series fuzz Usage (revision) N-03).
contract PartialDebitStockToken is StockToken {
    uint16 public debitBps = 10_000;

    function setHalfDebit(bool enabled) external {
        debitBps = enabled ? 5000 : 10_000;
    }

    function setDebitBps(uint16 bps) external {
        require(bps <= 10_000, "bps");
        debitBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (debitBps != 10_000 && from != address(0) && to != address(0)) {
            super._update(from, to, (value * debitBps) / 10_000);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice One. `balanceOf` - The vault. receive It's... 20 Thousand gas The targets are slower in the budget but still achievable in the ordinary transactions.
/// @dev Fixed workload instead of burning all forwards gas:The former can construct the border between "failure to read and failure to read" and "failure to read."
contract SlowBalanceStockToken is StockToken {
    uint256 private constant BALANCE_OF_WORK = 6000;

    function balanceOf(address account) public view override returns (uint256) {
        assembly ("memory-safe") {
            for { let i := 0 } lt(i, BALANCE_OF_WORK) { i := add(i, 1) } { pop(keccak256(0, 0)) }
        }
        return super.balanceOf(account);
    }
}

/// @notice Simulations are allowed to destroy shares from any address and to allow the balance to read the real risk combination of failure after upgrading.
contract IssuerBurnableUnreadableStockToken is StockToken {
    error BalanceUnreadable();

    bool public balanceUnreadable;

    function adminBurn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function setBalanceUnreadable(bool enabled) external {
        balanceUnreadable = enabled;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (balanceUnreadable) revert BalanceUnreadable();
        return super.balanceOf(account);
    }
}

/// @title GatedApprovalStockToken
/// @notice `approve` Yes, it is.**The issuer's own custom error** Rejected stock tokens.
///
/// CRITICAL It's not a bad token of imagination: real. GME It's... `approve` / `permit` It's compiled.
/// `onlyNotPaused` + `onlyNotBlocked`(`docs/research/robinhood-stock-token-permissions.md` 3),
/// So once the issuer is suspended, the gold is on the path.**First**That was the authorization that fell.
/// It exists only for one reason: to prove that the vault took that.**As it is.**No, not a "authority failure" for itself.
/// The latter mistook the "issuer presses the switch" for "our code is wrong."
contract GatedApprovalStockToken is StockToken {
    error IssuerPaused();

    bool public approvalsBlocked;

    function setApprovalsBlocked(bool blocked) external {
        approvalsBlocked = blocked;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (approvalsBlocked) revert IssuerPaused();
        return super.approve(spender, value);
    }
}

/// @title SilentApprovalFailureStockToken
/// @notice `approve` Back `false` And...**No, no.** revert  -  -  Front EIP-20 The kind of token that the age left behind.
/// @dev If we don't return the value, the failure will be delayed until the pool. `transferFrom`,The reason for reporting is not related to the real cause.
contract SilentApprovalFailureStockToken is StockToken {
    function approve(address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @title DirtyBoolApprovalStockToken
/// @notice `approve` Returning one is neither 0 Not really. 1 The word.
///
/// CRITICAL This shape is one.**Wrongs disappear.** Way:`abi.decode(ret, (bool))` The blogger says that the government is not going to be able to take the decision.
/// solc . Checker direct `revert(0, 0)`  -  -  Empty returndata.So the "failure of authorization" can't be the reason why they can't get to each other.
/// We can't get our own text string. Front end. rule 004 The blogger says that the government is not going to be able to show anything when it shows up.
/// The luck is to see naked. revert,and out-of-gas I can't tell.
///
/// @dev `ClearingPool._readGating` The same thing was recorded and pressed with the entire note `uint256` - I'm sorry.
///      It's not zero, so this token is authorized.**Success** -  - But it has to take our own decision, not blow the whole thing up. revert.
contract DirtyBoolApprovalStockToken is StockToken {
    function approve(address spender, uint256 value) public override returns (bool) {
        // The authorization itself is as it should be -- the only thing that's broken is the...**Encoding of returned values**,That's exactly what I'm trying to measure.
        _approve(_msgSender(), spender, value);
        assembly {
            mstore(0x00, 2)
            return(0x00, 0x20)
        }
    }
}

/// @notice The recipient receives the full amount of the transfer and the fees are used as additional deductions by the sender.
/// @dev Switches are activated after deposit completion, and the special construction of the pool is overpaid `exercise` The path to the weight of the row.
contract SenderPaysFeeStockToken is StockToken {
    uint16 public senderFeeBps;

    function setSenderFeeBps(uint16 bps) external {
        require(bps <= 10_000, "fee > 100%");
        senderFeeBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (senderFeeBps == 0 || from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        super._update(from, to, value);
        uint256 fee = (value * senderFeeBps) / 10_000;
        if (fee != 0) super._update(from, TAX_SINK, fee);
    }
}

/// @title ReentrantStockToken
/// @notice Yes.**Transfer process**Redirecting external stock tokens.
///
/// # Why does this double have to exist?
///
/// `depositAndMint` The amount of casting is "the balance before and after transfer".**Natural sensitivity to re-entry.**:
///
/// ```
/// Outer layer:before = B                      -> Transfer T1
///                                                   The token is retweeted in the transfer.
/// Inner layer:before = B + T1 -> Transfer T2 -> delta = T2 -> Cast T2
///
/// Outer layer:after = B + T1 + T2 -> delta = T1 + T2 -> And cast again. T1 + T2
/// ```
///
/// The collateral comes in. `T1 + T2`,The certificate is forged. `T1 + 2T2`  -  -  **No Variable 1 and 2 It's a dead end.**.
///
/// And the pool is right.**Any**The stock is all on.`openSeries` No permit. See you. `ClearingPool` The blogger adds:
/// So this path is achievable, not theoretical. So here it is.**Heavy**No, not manners.
///
/// The right side of the line is {ReentrantMemeToken};How do you call back, how do you remember how you fail? {ReentrancyInjector}.
contract ReentrantStockToken is StockToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _fireReentrancy(from);
    }
}

/// @title PreUpdateReentrantStockToken
/// @notice I'm just saying, but I'm calling back.**Before the change in balance**.
///
/// CRITICAL This is the shape of the stitches on the side of the vault.{ReentrantStockToken} I'll call back when I'm done.**We've reduced it.**It's...
/// Balance, then any "balance" vs "The baseline" is a natural safety comparison -- it doesn't prove it. `CallVault` The order of the accounts is correct.
///
/// The dangerous sequence is this: the vault is moving the balance out, transferring it.**It's not working yet.**,Call back the vault. `sync()`.
/// The balance is still full.**Before**Just... `accountedQuote` Cleared the zero, this time. `sync()` I'll see you.
/// Full balance, baseline 0,So the baseline is re-instated to full; once the outer transfer actually occurs, the baseline is permanently above the real balance --
/// `balance <= accountedQuote` The government has been trying to reduce the number of people who have been receiving income.**The vault is locked and it's not ringing.**(Normative rule 010-3).
///
/// @dev Use with pool side (%2)`ReentrantStockToken`,The balance of the cast is counted over and over again) and is divided between two different stitches.
///      Common set {ReentrancyInjector}.
contract PreUpdateReentrantStockToken is StockToken, ReentrancyInjector {
    function _update(address from, address to, uint256 value) internal override {
        _fireReentrancy(from);
        super._update(from, to, value);
    }
}
