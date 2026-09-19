package router

import (
	"errors"
	"io"
	"log/slog"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	routerv1 "github.com/example/fleet-telemetry/gen/router/v1"
)

type Server struct {
	routerv1.UnimplementedRealtimeRouterServer
	Hub    *Hub
	Buffer int
	Log    *slog.Logger
}

// Subscribe is opened by each dashboard-api pod. The first message must be Hello;
// subsequent InterestUpdates replace the subscriber's routing interest.
func (s *Server) Subscribe(stream routerv1.RealtimeRouter_SubscribeServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	hello := first.GetHello()
	if hello == nil || hello.GetSubscriberId() == "" {
		return status.Error(codes.InvalidArgument, "first message must be Hello with subscriber_id")
	}
	sub := NewSubscriber(hello.GetSubscriberId(), s.Buffer)
	s.Hub.Add(sub)
	defer s.Hub.Remove(sub)
	log := s.Log.With("subscriber", sub.ID)
	log.Info("subscriber connected")
	defer log.Info("subscriber disconnected")

	recvErr := make(chan error, 1)
	go func() {
		for {
			req, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			if u := req.GetInterest(); u != nil {
				sub.SetInterest(InterestFromProto(u))
				log.Debug("interest updated", "version", u.GetVersion(), "all", u.GetAll(),
					"fleets", len(u.GetFleetIds()), "vins", len(u.GetVins()))
			}
		}
	}()

	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case err := <-recvErr:
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		case ev := <-sub.Out:
			if err := stream.Send(ev); err != nil {
				return err
			}
		}
	}
}
