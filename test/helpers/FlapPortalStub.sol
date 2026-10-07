// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFlapPortalLens} from "../../src/interfaces/IFlapPortalLens.sol";

/// @title FlapPortalStub
/// @notice Flap `Portal` Camera double:**Every field can be done.**,And it can return several malformations as needed.
///
/// # CRITICAL It's also "undermarked and no" non-revolving evidence.
///
/// `PriceSource` No, I'm fine. `abi.decode`,It's just press.**Subscript**From 576 Take the four fields in the byte (for the reasons there).
/// The underwritten error will not fail, nor will it be read-only. `PriceSource` Your own test is leaking.
///
/// So this double. `Honest` The branch is leaving deliberately. **Solidity Your own. ABI Encoder**Back
/// {IFlapPortalLens.TokenStateV8Safe}:Encoding order by compiler struct The declaration is generated,
/// and `PriceSource` The four constants.**No common source.**.The two sides are on the right side, and the bottom line is proven.
///
/// | Mode | The simulation is... |
/// |---|---|
/// | `Honest` | Read normally |
/// | `Revert` | No token exists - real Portal Report `TokenNotFound(address)`(Actual `0xde6137d1`) |
/// | `Short` | Insufficient data for returns 576 Bytes (inFlap I've changed the camera, or the proxy's wrong finger. |
/// | `BurnGas` | The camera is back to the past limit of burnout. gas |
/// | `Flood` | Returns a large amount of data - copy its account**Payable by caller and not within limit gas Inside** |
/// | `DirtyPool` | Maintenance 576 byte shape, but will `pool` It's... address word High 96 Punctuational |
contract FlapPortalStub {
    enum Mode {
        Honest,
        Revert,
        Short,
        BurnGas,
        Flood,
        DirtyPool
    }

    /// @dev and {HostileQuoteToken} Same scale: in 50 Thousand gas The return data are derived from the limits.
    uint256 private constant FLOOD_BYTES = 9000 * 32;

    Mode public mode;

    mapping(address token => IFlapPortalLens.TokenStateV8Safe state) private _states;

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setState(address token, IFlapPortalLens.TokenStateV8Safe calldata state) external {
        _states[token] = state;
    }

    /// @dev Curve Phase (Current)`status = 1`)It's a common setup.
    function setCurve(address token, address quoteToken, uint256 price) external {
        IFlapPortalLens.TokenStateV8Safe storage s = _states[token];
        s.status = 1;
        s.quoteTokenAddress = quoteToken;
        s.price = price;
        s.pool = address(0);
        s.tokenVersion = 6;
    }

    /// @dev After graduation (%)`status = 4`)Commonly used typologies: curve price zero, pool address in position - consistent with actual measurements.
    function setGraduated(address token, address quoteToken, address pool) external {
        IFlapPortalLens.TokenStateV8Safe storage s = _states[token];
        s.status = 4;
        s.quoteTokenAddress = quoteToken;
        s.price = 0;
        s.pool = pool;
        s.tokenVersion = 6;
    }

    function setStatus(address token, uint8 status) external {
        _states[token].status = status;
    }

    function getTokenV8Safe(address token) external view returns (IFlapPortalLens.TokenStateV8Safe memory) {
        Mode m = mode;

        if (m == Mode.Revert) {
            // Real Portal Error shape:`TokenNotFound(address)`.
            revert(unicode"stub portal: TokenNotFound");
        }

        if (m == Mode.Short) {
            assembly {
                mstore(0, 1)
                return(0, 0x40)
            }
        }

        if (m == Mode.Flood) {
            uint256 size = FLOOD_BYTES;
            assembly {
                return(0, size)
            }
        }

        if (m == Mode.DirtyPool) {
            bytes memory out = abi.encode(_states[token]);
            assembly ("memory-safe") {
                // `pool` Yes. 18 Fields struct of 14 individual 0-based ABI word.
                let poolWord := add(add(out, 0x20), mul(14, 0x20))
                mstore(poolWord, or(mload(poolWord), shl(160, 1)))
                return(add(out, 0x20), mload(out))
            }
        }

        if (m == Mode.BurnGas) {
            // Run for the cycle.`x` It has to be actually used, or the optimizer will delete the whole passage as dead code.
            // So this one is gonna be quiet and degenerated. `Honest`(and {HostileQuoteToken} Same pit.
            uint256 x = uint256(uint160(token));
            for (uint256 i = 0; i < type(uint256).max; i++) {
                x = uint256(keccak256(abi.encode(x, i)));
            }
            IFlapPortalLens.TokenStateV8Safe memory burned;
            burned.price = x;
            return burned;
        }

        return _states[token];
    }
}
