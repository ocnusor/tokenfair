pragma solidity ^0.4.21;

import "./Ownable.sol";
import "./SafeMath.sol";
import "./StandardToken.sol";


/**
 * @title TeamToken
 * @dev The team token. One token represents a team. TeamToken is also an ERC20 standard token.
 */
contract TeamToken is StandardToken, Ownable {
    event Buy(address indexed token, address indexed from, uint256 value, uint256 weiValue);
    event Sell(address indexed token, address indexed from, uint256 value, uint256 weiValue);
    event BeginGame(address indexed team1, address indexed team2, uint64 gameTime);
    event EndGame(address indexed team1, address indexed team2, uint8 gameResult);
    event ChangeStatus(address indexed team, uint8 status);

    /**
    * @dev Token price based on ETH
    */
    uint256 public price;
    /**
    * @dev status=0 buyable & sellable, user can buy or sell the token.
    * status=1 not buyable & not sellable, user cannot buy or sell the token.
    */
    uint8 public status;
    /**
    * @dev The game start time. gameTime=0 means game time is not enabled or not started.
    */
    uint64 public gameTime;
    /**
    * @dev The fee owner. The fee will send to this address.
    */
    address public feeOwner;
    /**
    * @dev Game opponent, gameOpponent is also a TeamToken.
    */
    address public gameOpponent;

    /**
    * @dev Team name and team symbol will be ERC20 token name and symbol. Token decimals will be 3.
    * Token total supply will be 0. The initial price will be 1 szabo (1000000000000 Wei)
    */
    constructor(string _teamName, string _teamSymbol, address _feeOwner) public {
        name = _teamName;
        symbol = _teamSymbol;
        decimals = 3;
        totalSupply_ = 0;
        price = 1 szabo;
        feeOwner = _feeOwner;
        owner = msg.sender;
    }

    /**
    * @dev Sell Or Transfer the token.
    *
    * Override ERC20 transfer token function. If the _to address is not this TeamToken,
    * then call the super transfer function, which will be ERC20 token transfer.
    * Otherwise, the user want to sell the token (TeamToken -> ETH).
    * @param _to address The address which you want to transfer/sell to
    * @param _value uint256 the amount of tokens to be transferred/sold
    */
    function transfer(address _to, uint256 _value) public returns (bool) {
        if (_to != address(this)) {
            return super.transfer(_to, _value);
        }
        require(_value <= balances_[msg.sender] && status == 0);
        // If gameTime is enabled (larger than 1514764800 (2018-01-01))
        if (gameTime > 1514764800) {
            // We will not allowed to sell after 5 minutes (300 seconds) before game start
            require(gameTime - 300 > block.timestamp);
        }
        balances_[msg.sender] = balances_[msg.sender].sub(_value);
        totalSupply_ = totalSupply_.sub(_value);
        uint256 weiAmount = price.mul(_value);
        msg.sender.transfer(weiAmount);
        emit Transfer(msg.sender, _to, _value);
        emit Sell(_to, msg.sender, _value, weiAmount);
        return true;
    }

    /**
    * @dev Buy token using ETH
    *
    * User send ETH to this TeamToken, then his token balance will be increased based on price.
    * The total supply will also be increased.
    */
    function() payable public {
        require(status == 0 && price > 0);
        // If gameTime is enabled (larger than 1514764800 (2018-01-01))
        if (gameTime > 1514764800) {
            // We will not allowed to sell after 5 minutes (300 seconds) before game start
            require(gameTime - 300 > block.timestamp);
        }
        uint256 amount = msg.value.div(price);
        balances_[msg.sender] = balances_[msg.sender].add(amount);
        totalSupply_ = totalSupply_.add(amount);
        emit Transfer(address(this), msg.sender, amount);
        emit Buy(address(this), msg.sender, amount, msg.value);
    }

    /**
    * @dev The the game status.
    *
    * status = 0 buyable & sellable, user can buy or sell the token.
    * status=1 not buyable & not sellable, user cannot buy or sell the token.
    * @param _status The game status.
    */
    function changeStatus(uint8 _status) onlyOwner public {
        require(status != _status);
        status = _status;
        emit ChangeStatus(address(this), _status);
    }

    /**
    * @dev Finish the game
    *
    * If the time is older than one month after 2017-18 UEFA Champions league (2018-05-26 19:45:00 UTC)
    * The owner has permission to transfer the balance to the feeOwner.
    * The user can get back the balance using the website after this time.
    */
    function finish() onlyOwner public {
        // 2018-06-25 18:45:00 UTC
        require(block.timestamp >= 1529952300);
        feeOwner.transfer(address(this).balance);
    }

    /**
    * @dev Start the game
    *
    * Start a new game. Initialize game opponent, game time and status.
    * @param _gameOpponent The game opponent contract address
    * @param _gameTime The game begin time. optional
    */
    function beginGame(address _gameOpponent, uint64 _gameTime) onlyOwner public {
        require(_gameOpponent != address(0) && _gameOpponent != address(this) && gameOpponent == address(0));
        // 1514764800 = 2018-01-01
        // 1546300800 = 2019-01-01
        require(_gameTime == 0 || (_gameTime > 1514764800 && _gameTime < 1546300800));
        gameOpponent = _gameOpponent;
        gameTime = _gameTime;
        status = 0;
        emit BeginGame(address(this), _gameOpponent, _gameTime);
    }

    /**
    * @dev End the game with game final result.
    *
    * The function only allow to be called with the lose team or the draw team with large balance.
    * We have this rule because the lose team or draw team will large balance need transfer balance to opposite side.
    * This function will also change status of opposite team by calling transferFundAndEndGame function.
    * So the function only need to be called one time for the home and away team.
    * The new price will be recalculated based on the new balance and total supply.
    *
    * Balance transfer rule:
    * 1. The rose team will transfer all balance to opposite side.
    * 2. If the game is draw, the balances of two team will go fifty-fifty.
    * 3. If game is canceled, the balance is not touched and the game states will be reset to initial states.
    * 4. The fee will be 5% of each transfer amount.
    * @param _gameOpponent The game opponent contract address
    * @param _gameResult game result. 1=lose, 2=draw, 3=cancel, 4=win (not allow)
    */
    function endGame(address _gameOpponent, uint8 _gameResult) onlyOwner public {
        require(gameOpponent != address(0) && gameOpponent == _gameOpponent);
        uint256 amount = address(this).balance;
        uint256 opAmount = gameOpponent.balance;
        require(_gameResult == 1 || (_gameResult == 2 && amount >= opAmount) || _gameResult == 3);
        TeamToken op = TeamToken(gameOpponent);
        if (_gameResult == 1) {
            // Lose
            if (amount > 0 && totalSupply_ > 0) {
                uint256 lostAmount = amount;
                // If opponent has supply
                if (op.totalSupply() > 0) {
                    // fee is 5%
                    uint256 feeAmount = lostAmount.div(20);
                    lostAmount = lostAmount.sub(feeAmount);
                    feeOwner.transfer(feeAmount);
                    op.transferFundAndEndGame.value(lostAmount)();
                } else {
                    // If opponent has not supply, then send the lose money to fee owner.
                    feeOwner.transfer(lostAmount);
                    op.transferFundAndEndGame();
                }
            } else {
                op.transferFundAndEndGame();
            }
        } else if (_gameResult == 2) {
            // Draw
            if (amount > opAmount) {
                lostAmount = amount.sub(opAmount).div(2);
                if (op.totalSupply() > 0) {
                    // fee is 5%
                    feeAmount = lostAmount.div(20);
                    lostAmount = lostAmount.sub(feeAmount);
                    op = TeamToken(gameOpponent);
                    feeOwner.transfer(feeAmount);
                    op.transferFundAndEndGame.value(lostAmount)();
                } else {
                    feeOwner.transfer(lostAmount);
                    op.transferFundAndEndGame();
                }
            } else if (amount == opAmount) {
                op.transferFundAndEndGame();
            } else {
                // should not happen
                revert();
            }
        } else if (_gameResult == 3) {
            //canceled
            op.transferFundAndEndGame();
        } else {
            // should not happen
            revert();
        }
        endGameInternal();
        if (totalSupply_ > 0) {
            price = address(this).balance.div(totalSupply_);
        }
        emit EndGame(address(this), _gameOpponent, _gameResult);
    }

    /**
    * @dev Reset team token states
    *
    */
    function endGameInternal() private {
        gameOpponent = address(0);
        gameTime = 0;
        status = 0;
    }

    /**
    * @dev Reset team states and recalculate the price.
    *
    * This function will be called by opponent team token after end game.
    * It accepts the ETH transfer and recalculate the new price based on
    * new balance and total supply.
    */
    function transferFundAndEndGame() payable public {
        require(gameOpponent != address(0) && gameOpponent == msg.sender);
        if (msg.value > 0 && totalSupply_ > 0) {
            price = address(this).balance.div(totalSupply_);
        }
        endGameInternal();
    }
}