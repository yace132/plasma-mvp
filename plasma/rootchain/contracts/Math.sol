pragma solidity 0.4.18;

/**
 * @title Math
 * @dev Assorted math operations 
 */

library Math {
    function max(uint256 a, uint256 b)
        internal
        pure
        returns (uint256)
    {
        if (a > b) 
            return a;
        return b;
    }
}
