// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor} from "./flap/IVaultSchemasV1.sol";

import {PriceSource} from "./PriceSource.sol";
import {IClearingPool} from "./interfaces/IClearingPool.sol";

interface IWNative {
    function deposit() external payable;
}

/// @notice Non-upgradeable Flap Custom Vault. Guardian may withdraw assets held here,
/// but cannot change project identity, creator, series policy or Pool collateral.
contract WarrantVault is VaultBaseV3 {
    uint256 private constant QUOTE_BALANCE_GAS = 200_000;

    uint256 internal constant TWAP_SAMPLES = 24;

    uint256 internal constant SAMPLE_INTERVAL = 1 hours;

    uint256 internal constant SAMPLE_JITTER = 5 minutes;

    uint256 internal constant MAX_SAMPLE_GAP = SAMPLE_INTERVAL + SAMPLE_JITTER;

    uint256 internal constant MAX_SAMPLE_AGE = 2 hours;

    uint256 internal constant MIN_TWAP_WINDOW = 24 hours;

    uint256 internal constant MAX_TWAP_WINDOW = 30 hours;

    uint256 internal constant TWAP_OK = 0;
    uint256 internal constant TWAP_RING_NOT_FULL = 1;
    uint256 internal constant TWAP_STALE = 2;
    uint256 internal constant TWAP_WINDOW_TOO_SHORT = 3;
    uint256 internal constant TWAP_WINDOW_TOO_LONG = 4;
    uint256 internal constant TWAP_SAMPLE_GAP = 5;

    uint64 internal constant EXPIRY_PERIOD = 7 days;

    uint64 internal constant EXPIRY_OFFSET = 45 hours;

    uint64 internal constant MIN_SERIES_LIFETIME = 7 days;

    uint64 internal constant OPEN_WINDOW = 24 hours;

    uint256 internal constant STRIKE_BPS = 8000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint256 public constant CREATOR_FEE_BPS = 1000;
    uint256 public constant PROTOCOL_FEE_BPS = 1000;

    uint256 internal constant OPEN_OK = 0;
    uint256 internal constant OPEN_ALREADY_OPEN = 1;
    uint256 internal constant OPEN_TOO_EARLY = 2;
    uint256 internal constant OPEN_TWAP_UNAVAILABLE = 3;
    uint256 internal constant OPEN_STRIKE_ROUNDS_TO_ZERO = 4;
    uint256 internal constant OPEN_STRIKE_TOO_LARGE = 5;

    struct Sample {
        uint64 ts;
        uint192 price;
    }

    IClearingPool public immutable pool;

    address public immutable merkleDistributor;

    address public immutable portal;

    address private immutable _quoteToken;

    bool private immutable _wrapsNative;

    address public immutable taxToken;

    address public immutable creator;
    address public immutable protocolFeeReceiver;

    uint256 public accountedQuote;

    uint128 public strike;

    uint64 public seriesExpiry;

    uint64 public lastRevenueAt;

    uint8 private _ringNext;

    uint64 public lastSampleAt;

    Sample[TWAP_SAMPLES] private _ring;

    Sample private _twapBoundary;

    uint256 public creatorAccrued;

    bool private _locked;
    bool private _emergencyQuoteTransfer;
    bool private _emergencyQuoteWake;
    uint256 public accountedNative;
    uint256 public creatorImpaired;
    uint256 public creatorClaimed;
    uint256 public protocolAccrued;
    uint256 public protocolClaimed;
    uint256 public protocolImpaired;
    uint256 private _protocolRemainder;

    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    event CreatorFeeImpaired(uint256 amount, uint256 impairedTotal);
    event ProtocolFeeAccrued(uint256 amount, uint256 accruedTotal);
    event ProtocolFeeClaimed(uint256 amount, uint256 claimedTotal);
    event ProtocolFeeImpaired(uint256 amount, uint256 impairedTotal);

    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅 Guardian");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, unicode"Reentrant call / 重入调用");
        _locked = true;
        _;
        _locked = false;
    }

    event VaultInitialized(address indexed taxToken, address indexed quoteToken);

    event RevenueRecognized(uint256 newRevenue, uint256 accountedTotal);

    event QuoteBalanceUnreadable(address indexed quoteToken);

    event TwapSampled(uint64 ts, uint256 price, uint8 source);

    event WeeklySeriesOpened(uint256 indexed seriesId, uint64 expiry, uint128 strike, uint256 twapPrice);

    event TwapSampleFailed(uint8 reason);

    event RevenueDeposited(uint256 indexed seriesId, uint256 sent, uint256 minted);

    event RevenueDeferred(uint256 balance, uint64 seriesExpiry);

    event CreatorFeeAccrued(uint256 amount, uint256 accruedTotal);

    event CreatorFeeClaimed(uint256 amount);

    constructor(
        IClearingPool pool_,
        address merkleDistributor_,
        address portal_,
        address taxToken_,
        address quoteToken_,
        address creator_,
        bool wrapsNative_,
        address protocolFeeReceiver_
    ) {
        require(address(pool_) != address(0), unicode"Clearing pool is the zero address / 清算池是零地址");
        require(merkleDistributor_ != address(0), unicode"Distributor is the zero address / 分发合约是零地址");
        require(portal_ != address(0), unicode"Portal is the zero address / 价源 Portal 是零地址");
        require(taxToken_ != address(0), unicode"Tax token is the zero address / 税收代币是零地址");
        require(quoteToken_ != address(0), unicode"Quote token is the zero address / 收入币种是零地址");
        require(quoteToken_.code.length != 0, unicode"Quote token has no code / 收入币种地址上没有代码");
        require(creator_ != address(0), unicode"Creator is the zero address / 发射者是零地址");
        require(
            protocolFeeReceiver_ != address(0) && protocolFeeReceiver_ != address(this),
            unicode"Invalid protocol receiver / 协议收款地址无效"
        );

        pool = pool_;
        merkleDistributor = merkleDistributor_;
        portal = portal_;
        taxToken = taxToken_;
        _quoteToken = quoteToken_;
        creator = creator_;
        protocolFeeReceiver = protocolFeeReceiver_;
        _wrapsNative = wrapsNative_;

        emit VaultInitialized(taxToken_, quoteToken_);
    }

    receive() external payable {
        if (_locked) {
            if (_emergencyQuoteTransfer && msg.value == 0) _emergencyQuoteWake = true;
            return;
        }
        _recognize();
    }

    function sync() external {
        if (_locked) return;
        _locked = true;
        _wrapNative(); // 原生档：先把到账的原生 BNB 包进 WBNB，再记账（§7.14）；ERC20 档 no-op
        _recognize();
        _locked = false;
    }

    function processRevenue() external nonReentrant returns (uint256 minted) {
        _wrapNative();

        _recognize();

        uint256 balance = _requiredQuoteBalance();
        _recognizeBalance(balance);

        uint256 accrued = creatorAccrued;
        uint256 reserved = accrued + protocolAccrued;
        uint256 available = balance > reserved ? balance - reserved : 0;
        if (available == 0) return 0;

        uint64 expiry = seriesExpiry;
        if (strike == 0 || block.timestamp >= expiry) {
            emit RevenueDeferred(available, expiry);
            return 0;
        }

        uint256 seriesId = pool.seriesIdOf(taxToken, _quoteToken, expiry);

        uint256 cut = available / 9;

        _approveQuote(available - cut);
        minted = pool.depositAndMint(seriesId, merkleDistributor, available - cut);
        _approveQuote(0);

        uint256 balanceAfter = _requiredQuoteBalance();
        uint256 sent = balanceAfter < balance ? balance - balanceAfter : 0;
        accountedQuote = balanceAfter;
        if (sent != 0) {
            lastRevenueAt = uint64(block.timestamp);
            uint256 confirmedCut = sent / 8;
            if (confirmedCut > cut) confirmedCut = cut;
            if (confirmedCut != 0) {
                creatorAccrued = accrued + confirmedCut;
                emit CreatorFeeAccrued(confirmedCut, accrued + confirmedCut);
            }
        }

        _impairUnsupportedReserve(balanceAfter);
        emit RevenueDeposited(seriesId, sent, minted);
    }

    function claimCreatorFee() external nonReentrant returns (uint256 claimed) {
        _wrapNative();

        _recognize();

        uint256 accrued = creatorAccrued;
        if (accrued == 0) return 0;

        uint256 balance = _requiredQuoteBalance();
        uint256 requested = accrued < balance ? accrued : balance;
        if (requested == 0) return 0;

        creatorAccrued = accrued - requested;

        _transferQuote(creator, requested);

        uint256 balanceAfter = _requiredQuoteBalance();
        uint256 debited = balance > balanceAfter ? balance - balanceAfter : 0;
        claimed = debited < accrued ? debited : accrued;
        if (claimed != requested) creatorAccrued = accrued - claimed;

        accountedQuote = balanceAfter;

        _impairUnsupportedReserve(balanceAfter);
        if (claimed != 0) {
            creatorClaimed += claimed;
            emit CreatorFeeClaimed(claimed);
        }
    }

    function claimProtocolFee() external nonReentrant returns (uint256 claimed) {
        _wrapNative();
        _recognize();
        uint256 accrued = protocolAccrued;
        if (accrued == 0) return 0;
        uint256 balance = _requiredQuoteBalance();
        uint256 requested = accrued < balance ? accrued : balance;
        if (requested == 0) return 0;
        protocolAccrued = accrued - requested;
        _emergencyQuoteTransfer = true;
        _emergencyQuoteWake = false;
        _transferQuote(protocolFeeReceiver, requested);
        require(!_emergencyQuoteWake, unicode"Quote wake during withdrawal / 提款期间收到币种回调");
        _emergencyQuoteTransfer = false;
        uint256 balanceAfter = _requiredQuoteBalance();
        require(balanceAfter <= balance, unicode"Quote inflow during claim / 领取期间收入回流");
        uint256 debited = balance > balanceAfter ? balance - balanceAfter : 0;
        require(debited <= accrued, unicode"Protocol debit exceeds reserve / 协议扣款超过储备");
        claimed = debited < accrued ? debited : accrued;
        protocolAccrued = accrued - claimed;
        accountedQuote = balanceAfter;
        _impairUnsupportedReserve(balanceAfter);
        if (claimed != 0) {
            protocolClaimed += claimed;
            emit ProtocolFeeClaimed(claimed, protocolClaimed);
        }
    }

    function _transferQuote(address to, uint256 amount) private {
        (bool ok, bytes memory ret) = _quoteToken.call(abi.encodeCall(IERC20.transfer, (to, amount)));

        if (!ok) {
            require(ret.length != 0, unicode"Quote token rejected the transfer / 收入币种拒绝了转账");
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        require(
            ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0),
            unicode"Quote token rejected the transfer / 收入币种拒绝了转账"
        );
    }

    function _approveQuote(uint256 amount) private {
        (bool ok, bytes memory ret) = _quoteToken.call(abi.encodeCall(IERC20.approve, (address(pool), amount)));

        if (!ok) {
            require(ret.length != 0, unicode"Quote token rejected the approval / 收入币种拒绝了授权");
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        require(
            ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0),
            unicode"Quote token rejected the approval / 收入币种拒绝了授权"
        );
    }

    function _recognize() private {
        _recognizeNative();
        (bool readable, uint256 balance) = _quoteBalance();
        if (!readable) {
            emit QuoteBalanceUnreadable(_quoteToken);
            return;
        }

        _recognizeBalance(balance);
        _impairUnsupportedReserve(balance + (_wrapsNative ? address(this).balance : 0));
    }

    // Recognize both currencies before moving BNB into WBNB. Wrapping advances
    // the WBNB baseline by the same amount and never creates a second revenue event.
    function _wrapNative() private {
        if (!_wrapsNative) return;
        _recognize();
        uint256 native = address(this).balance;
        if (native == 0) return;
        uint256 beforeWrap = _requiredQuoteBalance();
        IWNative(_quoteToken).deposit{value: native}();
        uint256 afterWrap = _requiredQuoteBalance();
        require(
            afterWrap >= beforeWrap && afterWrap - beforeWrap == native,
            unicode"Wrapped amount mismatch / 包装到账数量不符"
        );
        accountedNative = address(this).balance;
        accountedQuote = afterWrap;
    }

    function _recognizeNative() private {
        if (!_wrapsNative) return;
        uint256 balance = address(this).balance;
        uint256 prior = accountedNative;
        accountedNative = balance;
        if (balance > prior) {
            _accrueProtocolFee(balance - prior);
            lastRevenueAt = uint64(block.timestamp);
            emit RevenueRecognized(balance - prior, balance + accountedQuote);
        }
    }

    function _recognizeBalance(uint256 balance) private {
        uint256 accounted = accountedQuote;
        accountedQuote = balance;
        if (balance < accounted) {
            _impairUnsupportedReserve(balance + (_wrapsNative ? address(this).balance : 0));
        }
        if (balance <= accounted) return;
        _accrueProtocolFee(balance - accounted);
        lastRevenueAt = uint64(block.timestamp);
        emit RevenueRecognized(balance - accounted, balance);
    }

    function inTransit() public view returns (uint256 amount, bool exact) {
        (bool readable, uint256 balance) = _quoteBalance();
        if (!readable) return (0, false);
        uint256 pending = balance > accountedQuote ? balance - accountedQuote : 0;
        if (_wrapsNative) {
            uint256 native = address(this).balance;
            if (native > accountedNative) pending += native - accountedNative;
            balance += native;
        }
        uint256 pendingFee = pending / 10 + (pending % 10 + _protocolRemainder) / 10;
        uint256 accrued = creatorAccrued + protocolAccrued + pendingFee;
        return (balance > accrued ? balance - accrued : 0, true);
    }

    function _accrueProtocolFee(uint256 revenue) private {
        uint256 remainder = revenue % 10 + _protocolRemainder;
        uint256 fee = revenue / 10 + remainder / 10;
        _protocolRemainder = remainder % 10;
        if (fee == 0) return;
        protocolAccrued += fee;
        emit ProtocolFeeAccrued(fee, protocolAccrued);
    }

    function _quoteBalance() private view returns (bool readable, uint256 balance) {
        address quote = _quoteToken;

        bytes memory callData = abi.encodeCall(IERC20.balanceOf, (address(this)));
        uint256 gasCap = QUOTE_BALANCE_GAS;

        bool ok;
        uint256 returned;
        uint256 word;
        assembly ("memory-safe") {
            ok := staticcall(gasCap, quote, add(callData, 0x20), mload(callData), 0x00, 0x20)
            returned := returndatasize()
            word := mload(0x00)
        }

        if (!ok || returned < 32) return (false, 0);
        return (true, word);
    }

    function sampleTwap() external returns (bool written) {
        require(!_locked, unicode"Reentrant call / 重入调用");
        uint64 last = lastSampleAt;

        if (last != 0 && block.timestamp < uint256(last) + SAMPLE_INTERVAL) return false;

        (uint8 status, uint256 price, uint8 source) = PriceSource.spot(portal, taxToken, _quoteToken, _wrapsNative);
        if (status != PriceSource.OK) {
            emit TwapSampleFailed(status);
            return false;
        }

        uint256 slot = _ringNext;
        Sample memory evicted = _ring[slot];
        if (evicted.ts != 0) _twapBoundary = evicted;
        _ring[slot] = Sample({ts: uint64(block.timestamp), price: uint192(price)});
        _ringNext = uint8((slot + 1) % TWAP_SAMPLES);
        lastSampleAt = uint64(block.timestamp);

        emit TwapSampled(uint64(block.timestamp), price, source);
        return true;
    }

    function twap() public view returns (uint256 status, uint256 price) {
        uint256 next = _ringNext;
        (uint256 windowStatus, uint256 start) = _windowStatus(next);
        if (windowStatus != TWAP_OK) return (windowStatus, 0);

        (, Sample memory previous) = _sampleAtOrBefore(next, start);
        uint256 end = block.timestamp;
        uint256 weighted;
        for (uint256 i = 0; i < TWAP_SAMPLES; i++) {
            Sample memory current = _ring[(next + i) % TWAP_SAMPLES];
            if (uint256(current.ts) <= start) {
                previous = current;
                continue;
            }

            uint256 from = uint256(previous.ts);
            if (from < start) from = start;
            weighted += uint256(previous.price) * (uint256(current.ts) - from);
            previous = current;
        }
        uint256 tailFrom = uint256(previous.ts);
        if (tailFrom < start) tailFrom = start;
        weighted += uint256(previous.price) * (end - tailFrom);

        return (TWAP_OK, weighted / MIN_TWAP_WINDOW);
    }

    function _windowStatus(uint256 next) private view returns (uint256 status, uint256 start) {
        uint64 oldestTs = _ring[next].ts;
        if (oldestTs == 0) return (TWAP_RING_NOT_FULL, 0);

        uint256 newestTs = lastSampleAt;
        if (block.timestamp > newestTs + MAX_SAMPLE_AGE) return (TWAP_STALE, 0);

        if (block.timestamp < MIN_TWAP_WINDOW) return (TWAP_WINDOW_TOO_SHORT, 0);
        start = block.timestamp - MIN_TWAP_WINDOW;

        (bool found, Sample memory previous) = _sampleAtOrBefore(next, start);
        if (!found) return (TWAP_WINDOW_TOO_SHORT, start);
        if (block.timestamp - uint256(previous.ts) > MAX_TWAP_WINDOW) return (TWAP_WINDOW_TOO_LONG, start);
        if (_hasOversizedGap(next, start, block.timestamp)) return (TWAP_SAMPLE_GAP, start);
        return (TWAP_OK, start);
    }

    function _sampleAtOrBefore(uint256 next, uint256 at) private view returns (bool found, Sample memory sample) {
        Sample memory boundary = _twapBoundary;
        if (boundary.ts != 0 && uint256(boundary.ts) <= at) {
            found = true;
            sample = boundary;
        }

        for (uint256 i = 0; i < TWAP_SAMPLES; i++) {
            Sample memory current = _ring[(next + i) % TWAP_SAMPLES];
            if (uint256(current.ts) > at) break;
            found = true;
            sample = current;
        }
    }

    function _hasOversizedGap(uint256 next, uint256 start, uint256 end) private view returns (bool) {
        (, Sample memory previous) = _sampleAtOrBefore(next, start);

        for (uint256 i = 0; i < TWAP_SAMPLES; i++) {
            Sample memory current = _ring[(next + i) % TWAP_SAMPLES];
            if (uint256(current.ts) <= start) {
                previous = current;
                continue;
            }
            if (uint256(current.ts) - uint256(previous.ts) > MAX_SAMPLE_GAP) return true;
            previous = current;
        }

        return end - uint256(previous.ts) > MAX_SAMPLE_GAP;
    }

    function openSeries() external returns (uint256 seriesId, bool opened) {
        require(!_locked, unicode"Reentrant call / 重入调用");
        (uint256 status, uint64 expiry, uint128 newStrike, uint256 price) = _openSeriesPlan();

        if (status == OPEN_ALREADY_OPEN || status == OPEN_TOO_EARLY) {
            return (pool.seriesIdOf(taxToken, _quoteToken, seriesExpiry), false);
        }
        require(status == OPEN_OK, _openSeriesRefusal(status));

        seriesId = pool.openSeries(taxToken, _quoteToken, expiry, newStrike);
        strike = newStrike;
        seriesExpiry = expiry;

        emit WeeklySeriesOpened(seriesId, expiry, newStrike, price);
        return (seriesId, true);
    }

    function openSeriesStatus() external view returns (uint256 status, uint64 expiry, uint128 nextStrike) {
        (status, expiry, nextStrike,) = _openSeriesPlan();
    }

    function _openSeriesPlan() private view returns (uint256 status, uint64 expiry, uint128 nextStrike, uint256 price) {
        expiry = _nextExpiry(block.timestamp);

        uint64 current = seriesExpiry;
        if (current == expiry) return (OPEN_ALREADY_OPEN, expiry, 0, 0);
        if (current != 0 && block.timestamp + OPEN_WINDOW < current) return (OPEN_TOO_EARLY, expiry, 0, 0);

        uint256 twapStatus;
        (twapStatus, price) = twap();
        if (twapStatus != TWAP_OK) return (OPEN_TWAP_UNAVAILABLE, expiry, 0, 0);

        uint256 discounted = (price * STRIKE_BPS) / BPS_DENOMINATOR;
        if (discounted == 0) return (OPEN_STRIKE_ROUNDS_TO_ZERO, expiry, 0, price);
        if (discounted > type(uint128).max) return (OPEN_STRIKE_TOO_LARGE, expiry, 0, price);

        return (OPEN_OK, expiry, uint128(discounted), price);
    }

    function _nextExpiry(uint256 nowTs) internal pure returns (uint64) {
        uint256 shift = EXPIRY_PERIOD - EXPIRY_OFFSET;
        uint256 shifted = nowTs + MIN_SERIES_LIFETIME + shift;
        uint256 aligned = ((shifted + EXPIRY_PERIOD - 1) / EXPIRY_PERIOD) * EXPIRY_PERIOD;
        return uint64(aligned - shift);
    }

    function _openSeriesRefusal(uint256 status) private pure returns (string memory) {
        if (status == OPEN_TWAP_UNAVAILABLE) {
            return
                unicode"24h TWAP unavailable, call twap() for the reason / 24 小时 TWAP 不可用，原因调 twap() 读";
        }
        if (status == OPEN_STRIKE_ROUNDS_TO_ZERO) {
            return unicode"TWAP too low to price a strike / TWAP 太低，算不出非零行权价";
        }
        return unicode"Strike does not fit in uint128 / 行权价装不进 uint128";
    }

    function collateralToken() public view returns (address) {
        return _quoteToken;
    }

    function collateralDecimals() external view returns (uint8 decimals, bool readable) {
        address token = _quoteToken;
        bool ok;
        uint256 size;
        uint256 word;
        bytes4 selector = 0x313ce567;
        assembly ("memory-safe") {
            mstore(0, selector)
            ok := staticcall(20000, token, 0, 4, 0, 32)
            size := returndatasize()
            word := mload(0)
        }
        if (!ok || size < 32 || word > 255) return (0, false);
        return (uint8(word), true);
    }

    function _requiredQuoteBalance() private view returns (uint256 balance) {
        (bool readable, uint256 value) = _quoteBalance();
        require(readable, unicode"Quote balance unreadable / 收入币余额不可读");
        return value;
    }

    function _impairUnsupportedReserve(uint256 supported) private {
        uint256 creatorReserve = creatorAccrued;
        uint256 protocolReserve = protocolAccrued;
        uint256 reserved = creatorReserve + protocolReserve;
        if (reserved <= supported) return;
        uint256 creatorSupported = Math.mulDiv(supported, creatorReserve, reserved);
        uint256 protocolSupported = supported - creatorSupported;
        creatorAccrued = creatorSupported;
        protocolAccrued = protocolSupported;
        uint256 loss = creatorReserve - creatorSupported;
        if (loss != 0) {
            creatorImpaired += loss;
            emit CreatorFeeImpaired(loss, creatorImpaired);
        }
        loss = protocolReserve - protocolSupported;
        if (loss != 0) {
            protocolImpaired += loss;
            emit ProtocolFeeImpaired(loss, protocolImpaired);
        }
    }

    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(
            to != address(this) && (!_wrapsNative || to != _quoteToken),
            unicode"Invalid withdrawal recipient / 提款接收地址无效"
        );
        require(to != address(0), unicode"Recipient is zero / 接收地址为零");
        _recognize();
        uint256 amount = address(this).balance;
        if (_wrapsNative) _impairUnsupportedReserve(_requiredQuoteBalance());
        // Account for the known outflow before the recipient can return new BNB.
        if (_wrapsNative) accountedNative = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, unicode"Native withdrawal failed / 原生币提款失败");
        if (_wrapsNative) {
            _recognize();
        }
        emit EmergencyWithdrawNative(to, amount);
    }

    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(to != address(0), unicode"Recipient is zero / 接收地址为零");
        require(token != address(0), unicode"Token is zero / 代币为零");
        _recognize();
        uint256 amount = _tokenBalance(token);
        if (token == _quoteToken) {
            _impairUnsupportedReserve(_wrapsNative ? address(this).balance : 0);
        }
        _emergencyQuoteTransfer = token == _quoteToken;
        _emergencyQuoteWake = false;
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        require(
            ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0)),
            unicode"Token withdrawal failed / 代币提款失败"
        );
        // A quote ping during transfer makes gross outflow versus fresh inflow
        // unknowable for arbitrary ERC20s. Roll back rather than use fresh taxes
        // to support a creator reserve lost during this withdrawal.
        require(!_emergencyQuoteWake, unicode"Quote wake during withdrawal / 提款期间收到币种回调");
        _emergencyQuoteTransfer = false;
        if (token == _quoteToken) {
            uint256 afterBalance = _requiredQuoteBalance();
            require(afterBalance == 0, unicode"Incomplete quote withdrawal / 收入币全余额提款未完成");
            accountedQuote = 0;
            _recognizeNative();
        }
        emit EmergencyWithdrawToken(token, to, amount);
    }

    function _tokenBalance(address token) private view returns (uint256 value) {
        bool ok;
        uint256 size;
        bytes memory input = abi.encodeCall(IERC20.balanceOf, (address(this)));
        assembly ("memory-safe") {
            ok := staticcall(200000, token, add(input, 32), mload(input), 0, 32)
            size := returndatasize()
            value := mload(0)
        }
        require(ok && size >= 32, unicode"Token balance unreadable / 代币余额不可读");
    }

    function vaultQuoteToken() public view override returns (address) {
        return _wrapsNative ? address(0) : _quoteToken;
    }

    function wrapsNative() external view returns (bool) {
        return _wrapsNative;
    }

    function description() public view override returns (string memory) {
        string memory state = strike == 0
            ? unicode"no series open yet / 本周系列尚未开启"
            : (block.timestamp < seriesExpiry
                    ? unicode"series open / 本周系列已开"
                    : unicode"series expired / 系列已到期");
        (uint256 held, bool exact) = inTransit();
        string memory income = !exact
            ? unicode"in-transit amount unreadable / 在途收入数量不可读"
            : (held != 0
                    ? string.concat(unicode"在途收入 ", _decimal(held), " raw in transit")
                    : (lastRevenueAt == 0
                            ? unicode"no revenue seen yet / 尚未见到任何收入"
                            : unicode"nothing in transit / 当前没有在途收入"));
        (uint256 status,) = _windowStatus(_ringNext);
        return string.concat(
            "WarrantVault: ",
            state,
            "; strike=",
            _decimal(strike),
            "; expiry=",
            _decimal(seriesExpiry),
            "; ",
            income,
            "; lastRevenueAt=",
            _decimal(lastRevenueAt),
            status == TWAP_OK
                ? unicode"; 24h TWAP ready / 24 小时 TWAP 可用; status="
                : unicode"; 24h TWAP unavailable / 24 小时 TWAP 不可用; status=",
            _decimal(status),
            "; lastSampleAt=",
            _decimal(lastSampleAt)
        );
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "WarrantVault";
        schema.description = "Pool80%, creator10%, protocol10%. Permanent losses. Raw units.";
        schema.methods = new VaultMethodSchema[](35);
        schema.methods[0] = _schemaMethod("vaultQuoteToken", "Launch quote; zero means native BNB", false, 2);
        schema.methods[1] = _schemaMethod("collateralToken", "Pool collateral ERC20", false, 2);
        schema.methods[2] = _schemaMethod("wrapsNative", "BNB is lazily wrapped into collateral", false, 3);
        schema.methods[3] = _schemaMethod("pool", "Immutable clearing Pool", false, 2);
        schema.methods[4] = _schemaMethod("merkleDistributor", "Immutable warrant recipient", false, 2);
        schema.methods[5] = _schemaMethod("portal", "Immutable price source Portal", false, 2);
        schema.methods[6] = _schemaMethod("taxToken", "Project token identity", false, 2);
        schema.methods[7] = _schemaMethod("creator", "Immutable creator recipient", false, 2);
        schema.methods[8] = _schemaMethod("CREATOR_FEE_BPS", "Creator fee basis points", false, 1);
        schema.methods[9] = _schemaMethod("accountedQuote", "Recognized ERC20, raw units", false, 1);
        schema.methods[10] = _schemaMethod("accountedNative", "Recognized BNB, wei", false, 1);
        schema.methods[11] = _schemaMethod("creatorAccrued", "Creator reserve, raw units", false, 1);
        schema.methods[12] = _schemaMethod("creatorClaimed", "Consumed creator claims, raw units", false, 1);
        schema.methods[13] = _schemaMethod("creatorImpaired", "Permanent losses, raw units; never repaid", false, 1);
        schema.methods[14] = _schemaMethod("strike", "Raw MEME per 1e18 raw collateral", false, 4);
        schema.methods[15] = _schemaMethod("seriesExpiry", "Current series expiry, Unix seconds", false, 5);
        schema.methods[16] = _schemaMethod("lastRevenueAt", "Last income, Unix seconds", false, 5);
        schema.methods[17] = _schemaMethod("lastSampleAt", "Last price sample, Unix seconds", false, 5);
        schema.methods[18] = _schemaMethod("sync", "Public: recognize income; wrap BNB", true, 0);
        schema.methods[19] = _schemaMethod("sampleTwap", "Public: hourly sample", true, 3);
        schema.methods[20] = _schemaMethod("openSeries", "Public: TWAP weekly series", true, 769);
        schema.methods[21] = _schemaMethod("processRevenue", "Public: Pool80%, creator10%, protocol10%", true, 1);
        schema.methods[22] = _schemaMethod("claimCreatorFee", "Public: pay reserve to creator", true, 1);
        schema.methods[23] =
            _schemaMethod("emergencyWithdrawNative", "Guardian only: all BNB; permanent reserve loss", true, 0);
        schema.methods[23].inputs = new FieldDescriptor[](1);
        schema.methods[23].inputs[0] = FieldDescriptor("to", "address", "Nonzero to", 0);
        schema.methods[24] =
            _schemaMethod("emergencyWithdrawToken", "Guardian only: all selected ERC20; reconcile losses", true, 0);
        schema.methods[24].inputs = new FieldDescriptor[](2);
        schema.methods[24].inputs[0] = FieldDescriptor("token", "address", "Nonzero token", 0);
        schema.methods[24].inputs[1] = FieldDescriptor("to", "address", "Nonzero to", 0);
        schema.methods[25] =
            _schemaMethod("twap", "TWAP: 0 ready, 1 incomplete, 2 stale, 3 short, 4 old, 5 gap", false, 257);
        schema.methods[26] = _schemaMethod(
            "openSeriesStatus", "0 ready, 1 open, 2 early, 3 bad TWAP, 4 zero, 5 overflow", false, 263_425
        );
        schema.methods[27] = _schemaMethod("inTransit", "Less reserves/pending fee; exact=false unreadable", false, 769);
        schema.methods[28] = _schemaMethod("collateralDecimals", "Decimals; readable=false unknown", false, 774);
        schema.methods[29] = _schemaMethod("PROTOCOL_FEE_BPS", "Protocol fee basis points", false, 1);
        schema.methods[30] = _schemaMethod("protocolFeeReceiver", "Immutable protocol recipient", false, 2);
        schema.methods[31] = _schemaMethod("protocolAccrued", "Protocol reserve, raw units", false, 1);
        schema.methods[32] = _schemaMethod("protocolClaimed", "Consumed protocol claims, raw units", false, 1);
        schema.methods[33] = _schemaMethod("protocolImpaired", "Permanent protocol losses, raw units", false, 1);
        schema.methods[34] = _schemaMethod("claimProtocolFee", "Public: pay fixed protocol receiver", true, 1);
    }

    // Output type codes, one per byte: 1 uint256, 2 address, 3 bool,
    // 4 uint128, 5 uint64, 6 uint8. Compact encoding keeps CREATE bytecode deployable.
    function _schemaMethod(string memory name, string memory detail, bool write, uint32 types)
        private
        pure
        returns (VaultMethodSchema memory method)
    {
        method.name = name;
        method.description = detail;
        method.isWriteMethod = write;
        if (types == 0) return method;
        uint256 count;
        uint32 remaining = types;
        while (remaining != 0) {
            ++count;
            remaining >>= 8;
        }
        method.outputs = new FieldDescriptor[](count);
        bytes32 methodHash = keccak256(bytes(name));
        for (uint256 index; index < count; ++index) {
            uint256 code = (types >> (8 * index)) & 255;
            string memory fieldType = code == 1
                ? "uint256"
                : (code == 2
                        ? "address"
                        : (code == 3 ? "bool" : (code == 4 ? "uint128" : (code == 5 ? "time" : "uint256"))));
            string memory label = "value";
            if (methodHash == keccak256("twap")) {
                label = index == 0 ? "status" : "price";
            } else if (methodHash == keccak256("openSeriesStatus")) {
                label = index == 0 ? "status" : (index == 1 ? "expiry" : "nextStrike");
            } else if (methodHash == keccak256("openSeries")) {
                label = index == 0 ? "seriesId" : "opened";
            } else if (methodHash == keccak256("inTransit")) {
                label = index == 0 ? "amount" : "exact";
            } else if (methodHash == keccak256("collateralDecimals")) {
                label = index == 0 ? "decimals" : "readable";
            }
            method.outputs[index] = FieldDescriptor(label, fieldType, "Raw units or status; see method description", 0);
        }
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";

        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) {
            digits++;
        }

        bytes memory buffer = new bytes(digits);
        for (uint256 i = digits; i != 0; i--) {
            buffer[i - 1] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
