import { disconnectSocket } from '../actions/auth'
import { socketConnErr, socketConnected, socketAuthErr, socketAuthSuccess } from '../actions/socket'

/**
* Look to move this into its own npm modules
* 
*/
const SOCKET_API_URL = process.SOCKET_API_URL || 'ws://localhost:5000'

function addHandlers(socket, authToken, dispatch, eventName) {
  // Connection opened
  socket.onopen = event => {
    // connected to server but not authenticated
    dispatch(socketConnected(socket)); // pass ref to socket so dispatcher - socket middleware has access to new connected socket instance
    socket.send(authToken);
  }

  // Connection opened
  socket.onclose = event => {
    dispatch(disconnectSocket())
  }

  socket.onmessage = msg => {
    console.log(msg)
  }

  socket.onerror = err => {
    console.log(err)
  }

}

let connectedSocket = null;

function connHandler(dispatch, action, eventName) {
  if (action.type === "CONNECT_SOCKET") {
    const { token } = action
    const ws = new WebSocket(SOCKET_API_URL)
    console.log(ws)
    addHandlers(ws, token, dispatch, eventName);
  }

  if (action.type === "DISCONNECT_SOCKET") {
    if (connectedSocket) {
      connectedSocket.disconnect();
    }
  }
}

/**
* Allows you to register actions that when dispatched, send the action to the
* server via a socket.
* `criteria` may be a function (type, action) that returns true if you wish to send the
*  action to the server, array of action types, or a string prefix.
* the third parameter is an options object with the following properties:
* {
*   eventName,// a string name to use to send and receive actions from the server.
*   execute, // a function (action, emit, next, dispatch) that is responsible for
*            // sending the message to the server.
* }
*/
const reduxSocketIo = (criteria = [], eventName = "data") => ({
  dispatch,
  getState
}) => next => action => {
  connHandler(dispatch, action, eventName);
  console.log(action);

  if (connectedSocket) {
    if (evaluate(action, criteria)) {
      return defaultExecute(next, connectedSocket, eventName, action);
    }
    return next(action);
  }
  return next(action);

};

function evaluate(action, option) {
  if (!action || !action.type) {
    return false;
  }

  const { type } = action;
  let matched = false;
  if (typeof option === "function") {
    // Test function
    matched = option(type, action);
  } else if (typeof option === "string") {
    // String prefix
    matched = type.indexOf(option) === 0;
  } else if (Array.isArray(option)) {
    // Array of types
    matched = option.some(item => type.indexOf(item) === 0);
  }
  return matched;
}

function defaultExecute(next, connectedSocket, eventName, action) {
  connectedSocket.emit(eventName, action);
  return next(action);
}

export default reduxSocketIo;